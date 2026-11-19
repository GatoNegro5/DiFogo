// 3.1.92 (Fase 2A): transcripcion offline de la pista vocal 16 kHz mono
// (la que escribe `kar_stream_with`) con whisper.cpp via `whisper-rs`,
// SOLO en escritorio (Windows y macOS). En Android/iOS hay un stub.
//
// Salidas:
// - `words_json`: mismo esquema que `tool/gmx_whisper_words.py` y que lee
//   `lib/core/lyric_ai_align.dart` (`parseTimedWordsJson`):
//   {"dur": seg, "lang": "es", "model": "small",
//    "words": [[inicio_seg, fin_seg, " palabra"], ...]}
// - `lrc_text`: una linea `[mm:ss.xx] texto` por segmento, truncando las
//   centesimas igual que `_stamp` de `lyric_ai_align.dart`.
//
// Las funciones puras (parser de WAV, union de tokens, JSON y LRC) no tienen
// cfg y son privadas: se prueban sin modelo y el codegen de FRB (solo mira
// items `pub`) no las ve.
#![cfg_attr(not(any(test, target_os = "windows", target_os = "macos")), allow(dead_code))]

/// Resultado de `transcribe_vocals_wav` (tipos simples para FRB, Fase 2B).
pub struct WhisperTranscript {
    pub words_json: String,
    pub lrc_text: String,
    pub detected_lang: String,
}

/// Transcribe un WAV PCM 16-bit mono 16 kHz con un modelo GGML de whisper.
/// `language`: None o "auto" = deteccion automatica. 3.1.93: `String` y no
/// `&str` (con `Option<&str>` FRB genera un tipo opaco `Str` inusable).
pub fn transcribe_vocals_wav(
    wav_path: String,
    model_path: String,
    language: Option<String>,
) -> Result<WhisperTranscript, String> {
    transcribe_impl(&wav_path, &model_path, language.as_deref())
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn transcribe_impl(
    wav_path: &str,
    model_path: &str,
    language: Option<&str>,
) -> Result<WhisperTranscript, String> {
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    let lang_in: &str = match language.map(str::trim) {
        None | Some("") => "auto",
        Some(l) => l,
    };
    // set_language hace panic con un byte nulo: se valida antes.
    if lang_in.contains('\0') || lang_in.len() > 16 {
        return Err("whisper_bad_language".to_string());
    }
    let bytes = std::fs::read(wav_path).map_err(|e| format!("wav_read: {e}"))?;
    let samples = parse_wav_pcm16_mono16k(&bytes)?;
    drop(bytes);
    if samples.is_empty() {
        return Err("wav_no_samples".to_string());
    }
    let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
        .map_err(|e| format!("whisper_model: {e:?}"))?;
    let mut state = ctx
        .create_state()
        .map_err(|e| format!("whisper_state: {e:?}"))?;

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(2); // mismo presupuesto termico que ort
    params.set_token_timestamps(true);
    params.set_language(Some(lang_in));
    params.set_translate(false);
    params.set_no_context(true); // como condition_on_previous_text=False
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    state
        .full(params, &samples)
        .map_err(|e| format!("whisper_full: {e:?}"))?;

    let eot = ctx.token_eot();
    let mut words: Vec<TimedWordOut> = Vec::new();
    let mut lines: Vec<(i64, String)> = Vec::new();
    for s in 0..state.full_n_segments() {
        let Some(seg) = state.get_segment(s) else { continue };
        let text = seg.to_str_lossy().map(|t| t.into_owned()).unwrap_or_default();
        // timestamps de segmento en centesimas de segundo
        lines.push((seg.start_timestamp() * 10, text));
        let mut toks: Vec<RawToken> = Vec::new();
        for t in 0..seg.n_tokens() {
            let Some(tok) = seg.get_token(t) else { continue };
            let data = tok.token_data();
            toks.push(RawToken {
                bytes: tok.to_bytes().map(|b| b.to_vec()).unwrap_or_default(),
                t0_cs: data.t0,
                t1_cs: data.t1,
                special: tok.token_id() >= eot,
            });
        }
        words.extend(join_tokens_into_words(&toks));
    }

    let detected = whisper_rs::get_lang_str(state.full_lang_id_from_state())
        .unwrap_or(if lang_in == "auto" { "" } else { lang_in })
        .to_string();
    let dur = samples.len() as f64 / WAV_RATE as f64;
    Ok(WhisperTranscript {
        words_json: words_json(dur, &detected, &model_label(model_path), &words),
        lrc_text: lrc_text(&lines),
        detected_lang: detected,
    })
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn transcribe_impl(
    _wav_path: &str,
    _model_path: &str,
    _language: Option<&str>,
) -> Result<WhisperTranscript, String> {
    Err("whisper_desktop_only".to_string())
}

// ---------------------------------------------------------------------------
// Funciones puras (sin cfg, sin modelo)
// ---------------------------------------------------------------------------

const WAV_RATE: u32 = 16000;

/// WAV RIFF PCM 16-bit mono 16 kHz a muestras f32 en [-1, 1).
/// Recorre los chunks (acepta LIST u otros antes de `data`).
fn parse_wav_pcm16_mono16k(b: &[u8]) -> Result<Vec<f32>, String> {
    let u16le = |o: usize| u16::from_le_bytes([b[o], b[o + 1]]);
    let u32le = |o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
    if b.len() < 12 || &b[0..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return Err("wav_not_riff_wave".to_string());
    }
    let mut pos = 12usize;
    let mut fmt_ok = false;
    while pos + 8 <= b.len() {
        let id = &b[pos..pos + 4];
        let size = u32le(pos + 4) as usize;
        let body = pos + 8;
        if id == b"fmt " {
            if size < 16 || body + 16 > b.len() {
                return Err("wav_bad_fmt".to_string());
            }
            let format = u16le(body);
            let channels = u16le(body + 2);
            let rate = u32le(body + 4);
            let block_align = u16le(body + 12);
            let bits = u16le(body + 14);
            if format != 1 {
                return Err(format!("wav_not_pcm: {format}"));
            }
            if channels != 1 {
                return Err(format!("wav_channels: {channels}"));
            }
            if rate != WAV_RATE {
                return Err(format!("wav_rate: {rate}"));
            }
            if bits != 16 || block_align != 2 {
                return Err(format!("wav_bits: {bits}"));
            }
            fmt_ok = true;
        } else if id == b"data" {
            if !fmt_ok {
                return Err("wav_data_before_fmt".to_string());
            }
            if body + size > b.len() {
                return Err("wav_truncated".to_string());
            }
            let data = &b[body..body + size - (size % 2)];
            return Ok(data
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
                .collect());
        }
        // chunks con tamano impar llevan un byte de relleno
        pos = body.saturating_add(size).saturating_add(size & 1);
    }
    Err(if fmt_ok { "wav_no_data" } else { "wav_no_fmt" }.to_string())
}

/// Token crudo de whisper (bytes, no &str: un acento puede venir partido
/// entre dos tokens). t0/t1 en centesimas de segundo.
struct RawToken {
    bytes: Vec<u8>,
    t0_cs: i64,
    t1_cs: i64,
    special: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct TimedWordOut {
    start_s: f64,
    end_s: f64,
    text: String,
}

/// `[_BEG_]`, `[_TT_150]`, `[_SOT_]`, `<|es|>`... no son texto.
fn is_special_text(b: &[u8]) -> bool {
    (b.starts_with(b"[_") && b.ends_with(b"]")) || (b.starts_with(b"<|") && b.ends_with(b"|>"))
}

/// Une tokens en palabras como faster-whisper: un token que empieza con
/// espacio abre palabra nueva (el espacio se conserva); los demas se pegan
/// a la palabra en curso. Inicio = t0 del primer token, fin = t1 del ultimo.
fn join_tokens_into_words(tokens: &[RawToken]) -> Vec<TimedWordOut> {
    fn flush(out: &mut Vec<TimedWordOut>, cur: &mut Option<(Vec<u8>, i64, i64)>) {
        if let Some((bytes, t0, t1)) = cur.take() {
            let text = String::from_utf8_lossy(&bytes).into_owned();
            if !text.trim().is_empty() {
                out.push(TimedWordOut {
                    start_s: t0.max(0) as f64 / 100.0,
                    end_s: t1.max(t0).max(0) as f64 / 100.0,
                    text,
                });
            }
        }
    }
    let mut out = Vec::new();
    let mut cur: Option<(Vec<u8>, i64, i64)> = None;
    for t in tokens {
        if t.special || t.bytes.is_empty() || is_special_text(&t.bytes) {
            continue;
        }
        let opens = t.bytes[0] == b' ';
        match cur.as_mut() {
            Some((bytes, _, t1)) if !opens => {
                bytes.extend_from_slice(&t.bytes);
                *t1 = t.t1_cs;
            }
            _ => {
                flush(&mut out, &mut cur);
                cur = Some((t.bytes.clone(), t.t0_cs, t.t1_cs));
            }
        }
    }
    flush(&mut out, &mut cur);
    out
}

/// Numero como lo escribe json.dump de Python (12.0, 12.34); NaN/inf = 0.0.
fn json_num(v: f64) -> String {
    let v = if v.is_finite() { v } else { 0.0 };
    if v == v.trunc() && v.abs() < 1e15 {
        format!("{v:.1}")
    } else {
        format!("{v}")
    }
}

/// Cadena JSON con ensure_ascii (como json.dump): no ASCII como \uXXXX.
fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            '\u{08}' => o.push_str("\\b"),
            '\u{0C}' => o.push_str("\\f"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7E => {
                let mut buf = [0u16; 2];
                for u in c.encode_utf16(&mut buf) {
                    o.push_str(&format!("\\u{:04x}", u));
                }
            }
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// `{"dur": f64, "lang": str, "model": str, "words": [[s, e, " w"], ...]}`
fn words_json(dur_s: f64, lang: &str, model: &str, words: &[TimedWordOut]) -> String {
    let ws: Vec<String> = words
        .iter()
        .map(|w| format!("[{}, {}, {}]", json_num(w.start_s), json_num(w.end_s), json_str(&w.text)))
        .collect();
    format!(
        "{{\"dur\": {}, \"lang\": {}, \"model\": {}, \"words\": [{}]}}",
        json_num((dur_s * 1000.0).round() / 1000.0),
        json_str(lang),
        json_str(model),
        ws.join(", ")
    )
}

/// `ggml-small.bin` -> `small` (como el nombre de modelo del script Python).
fn model_label(model_path: &str) -> String {
    let stem = std::path::Path::new(model_path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    stem.strip_prefix("ggml-").unwrap_or(&stem).to_string()
}

/// `[mm:ss.xx]` truncando, igual que `_stamp` (lyric_ai_align.dart:57-61).
fn lrc_stamp(ms: i64) -> String {
    let ms = ms.max(0);
    format!("[{:02}:{:02}.{:02}]", ms / 60000, (ms % 60000) / 1000, (ms % 1000) / 10)
}

/// Segundos a ms truncando (59.999 s -> 59999 ms -> [00:59.99]).
#[cfg_attr(not(test), allow(dead_code))]
fn secs_to_ms_trunc(s: f64) -> i64 {
    if s.is_finite() && s > 0.0 {
        (s * 1000.0 + 1e-6).floor() as i64
    } else {
        0
    }
}

/// Una linea `[mm:ss.xx] texto` por segmento (sin lineas vacias), CRLF no:
/// `\n` como los .lrc que escribe la app.
fn lrc_text(lines: &[(i64, String)]) -> String {
    let mut o = String::new();
    for (ms, text) in lines {
        let t = text.trim();
        if t.is_empty() || is_special_text(t.as_bytes()) {
            continue;
        }
        o.push_str(&lrc_stamp(*ms));
        o.push(' ');
        o.push_str(t);
        o.push('\n');
    }
    o
}

#[cfg(test)]
mod whisper_lrc_tests {
    use super::*;

    fn wav(rate: u32, ch: u16, bits: u16, samples: &[i16]) -> Vec<u8> {
        let data_len = (samples.len() * 2) as u32;
        let mut v = Vec::new();
        v.extend_from_slice(b"RIFF");
        v.extend_from_slice(&(36 + data_len).to_le_bytes());
        v.extend_from_slice(b"WAVE");
        v.extend_from_slice(b"fmt ");
        v.extend_from_slice(&16u32.to_le_bytes());
        v.extend_from_slice(&1u16.to_le_bytes());
        v.extend_from_slice(&ch.to_le_bytes());
        v.extend_from_slice(&rate.to_le_bytes());
        v.extend_from_slice(&(rate * ch as u32 * bits as u32 / 8).to_le_bytes());
        v.extend_from_slice(&(ch * bits / 8).to_le_bytes());
        v.extend_from_slice(&bits.to_le_bytes());
        v.extend_from_slice(b"data");
        v.extend_from_slice(&data_len.to_le_bytes());
        for s in samples {
            v.extend_from_slice(&s.to_le_bytes());
        }
        v
    }

    fn tok(s: &str, t0: i64, t1: i64) -> RawToken {
        RawToken { bytes: s.as_bytes().to_vec(), t0_cs: t0, t1_cs: t1, special: false }
    }

    #[test]
    fn whisper_lrc_wav_valido_e_invalido() {
        let dir = std::env::temp_dir().join(format!("whisper_lrc_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("whisper_lrc_ok.wav");
        let src = [0i16, 16384, -16384, i16::MAX, i16::MIN, 1];
        std::fs::write(&p, wav(16000, 1, 16, &src)).unwrap();
        let got = parse_wav_pcm16_mono16k(&std::fs::read(&p).unwrap()).unwrap();
        assert_eq!(got.len(), 6);
        assert_eq!(got[0], 0.0);
        assert_eq!(got[1], 0.5);
        assert_eq!(got[2], -0.5);
        assert!(got[3] < 1.0 && got[3] > 0.9999);
        assert_eq!(got[4], -1.0);
        assert!(got.iter().all(|v| (-1.0..=1.0).contains(v)));

        // chunk LIST (impar, con relleno) antes de data: se salta
        let mut with_list = wav(16000, 1, 16, &src);
        let data_at = with_list.windows(4).position(|w| w == b"data").unwrap();
        let mut list = b"LIST".to_vec();
        list.extend_from_slice(&3u32.to_le_bytes());
        list.extend_from_slice(b"abc\0");
        with_list.splice(data_at..data_at, list);
        assert_eq!(parse_wav_pcm16_mono16k(&with_list).unwrap(), got);

        let err = |b: Vec<u8>| parse_wav_pcm16_mono16k(&b).unwrap_err();
        assert!(err(wav(44100, 1, 16, &src)).starts_with("wav_rate"));
        assert!(err(wav(16000, 2, 16, &src)).starts_with("wav_channels"));
        assert!(err(wav(16000, 1, 8, &src)).starts_with("wav_bits"));
        let mut float_fmt = wav(16000, 1, 16, &src);
        float_fmt[20] = 3; // IEEE float
        assert!(err(float_fmt).starts_with("wav_not_pcm"));
        assert_eq!(err(b"RIFX0000WAVE".to_vec()), "wav_not_riff_wave");
        assert_eq!(err(Vec::new()), "wav_not_riff_wave");
        let mut short = wav(16000, 1, 16, &src);
        short.truncate(short.len() - 3);
        assert_eq!(err(short), "wav_truncated");
        assert_eq!(err(wav(16000, 1, 16, &src)[..36].to_vec()), "wav_no_data");

        std::fs::remove_dir_all(&dir).unwrap();
        assert!(!dir.exists());
    }

    #[test]
    fn whisper_lrc_stamp_trunca_como_dart() {
        assert_eq!(lrc_stamp(secs_to_ms_trunc(59.999)), "[00:59.99]");
        assert_eq!(lrc_stamp(59_999), "[00:59.99]");
        assert_eq!(lrc_stamp(0), "[00:00.00]");
        assert_eq!(lrc_stamp(-5), "[00:00.00]");
        assert_eq!(lrc_stamp(1_009), "[00:01.00]");
        assert_eq!(lrc_stamp(61_239), "[01:01.23]");
        assert_eq!(lrc_stamp(10 * 60_000 + 5_678), "[10:05.67]");
        assert_eq!(lrc_stamp(125 * 60_000 + 1), "[125:00.00]");
        assert_eq!(secs_to_ms_trunc(12.34), 12_340);
        assert_eq!(secs_to_ms_trunc(f64::NAN), 0);
        let lrc = lrc_text(&[
            (12_340, " Hola mundo ".to_string()),
            (13_000, "   ".to_string()),
            (14_000, "[_BEG_]".to_string()),
            (659_999, " Otra linea".to_string()),
        ]);
        assert_eq!(lrc, "[00:12.34] Hola mundo\n[10:59.99] Otra linea\n");
    }

    #[test]
    fn whisper_lrc_union_de_tokens() {
        let mut beg = tok("[_BEG_]", 0, 0);
        beg.special = true;
        // acento partido en dos tokens: "can" + "ci" + 0xC3 | 0xB3 + "n"
        let a = tok(" can", 120, 130);
        let mut b1 = tok("ci", 130, 140);
        b1.bytes = vec![b'c', b'i', 0xC3];
        let mut b2 = tok("n", 140, 150);
        b2.bytes = vec![0xB3, b'n'];
        let toks = vec![
            beg,
            tok(" Hola", 100, 110),
            a,
            b1,
            b2,
            tok("[_TT_150]", 150, 150),
            tok("<|es|>", 150, 150),
            tok(",", 150, 151),
            tok(" ", 151, 151),
            tok(" Ya", 160, 170),
        ];
        let w = join_tokens_into_words(&toks);
        let texts: Vec<&str> = w.iter().map(|x| x.text.as_str()).collect();
        assert_eq!(texts, vec![" Hola", " canci\u{f3}n,", " Ya"]);
        assert_eq!((w[1].start_s, w[1].end_s), (1.2, 1.51));
        assert_eq!((w[0].start_s, w[0].end_s), (1.0, 1.1));
        // palabra suelta sin espacio al inicio (primer token) tambien vale
        let w2 = join_tokens_into_words(&[tok("Hey", 5, 9)]);
        assert_eq!(w2, vec![TimedWordOut { start_s: 0.05, end_s: 0.09, text: "Hey".into() }]);
        assert!(join_tokens_into_words(&[]).is_empty());
    }

    #[test]
    fn whisper_lrc_words_json_esquema_exacto() {
        let words = vec![
            TimedWordOut { start_s: 12.34, end_s: 12.71, text: " Hola".into() },
            TimedWordOut { start_s: 13.0, end_s: 13.5, text: " canci\u{f3}n \"x\"\\".into() },
        ];
        let j = words_json(215.40049, "es", &model_label("C:\\m\\ggml-small.bin"), &words);
        assert_eq!(
            j,
            "{\"dur\": 215.4, \"lang\": \"es\", \"model\": \"small\", \"words\": \
             [[12.34, 12.71, \" Hola\"], [13.0, 13.5, \" canci\\u00f3n \\\"x\\\"\\\\\"]]}"
        );
        assert_eq!(words_json(0.0, "", "m", &[]), "{\"dur\": 0.0, \"lang\": \"\", \"model\": \"m\", \"words\": []}");
        assert_eq!(json_str("\u{1F3B5}"), "\"\\ud83c\\udfb5\"");
        assert_eq!(json_num(f64::NAN), "0.0");
        assert_eq!(model_label("/x/ggml-large-v3.bin"), "large-v3");

        // Misma lectura que parseTimedWordsJson (Dart): d['words'], w[0] en
        // segundos -> ms redondeado, w[2] texto. Mini lector propio, sin serde.
        let ws = j.split("\"words\": [").nth(1).unwrap();
        let first = &ws[1..ws.find(']').unwrap()];
        let parts: Vec<&str> = first.splitn(3, ", ").collect();
        assert_eq!((parts[0].parse::<f64>().unwrap() * 1000.0).round() as i64, 12_340);
        assert_eq!(parts[1].parse::<f64>().unwrap(), 12.71);
        assert_eq!(parts[2], "\" Hola\"");
        // JSON bien formado: llaves y corchetes balanceados fuera de cadenas
        let (mut depth, mut in_s, mut esc) = (0i32, false, false);
        for c in j.chars() {
            if in_s {
                if esc { esc = false } else if c == '\\' { esc = true } else if c == '"' { in_s = false }
                continue;
            }
            match c {
                '"' => in_s = true,
                '{' | '[' => depth += 1,
                '}' | ']' => depth -= 1,
                _ => {}
            }
            assert!(depth >= 0);
        }
        assert_eq!((depth, in_s), (0, false));
        assert!(j.is_ascii());
    }
}
