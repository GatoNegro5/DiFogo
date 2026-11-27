//! 3.2.32 (DIF-29): arnes de reemplazo con el MISMO pipeline de la app
//! (Descargas YT -> encode_to_mp3 master, Masterizar -> master_rewrite,
//! Karaoke -> karaoke_separate) y el blindaje nuevo. Solo corre a mano:
//! `cargo test --release --lib dif29_arnes -- --ignored --nocapture` con
//! `GMX_DIF29_JOBS` (TSV: id, nombre, original) y `GMX_DIF29_OUT`.
//! Nunca escribe en la biblioteca: deja todo en `GMX_DIF29_OUT`.
use super::*;
use std::io::Write;

fn mono_of(p: &str) -> (Vec<f32>, u32) {
    let d = decode_channels(p, 0, 3600, 2).unwrap();
    (to_mono(&d), d.rate)
}

/// Espectrograma grueso: 64 bandas log de 0,5 s (CSV para el PNG) y el
/// mayor escalon espectral sostenido (media de 3 s antes contra 3 s despues).
fn spectro(mono: &[f32], rate: u32, csv: &str) -> (f32, u64) {
    use rustfft::num_complex::Complex;
    let n = 4096usize;
    let hop = (rate / 2) as usize;
    let mut planner = rustfft::FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n);
    let bands = 64usize;
    let nyq = rate as f32 / 2.0;
    let edges: Vec<usize> = (0..=bands)
        .map(|b| {
            let f = 40.0 * (nyq / 40.0).powf(b as f32 / bands as f32);
            ((f / nyq) * (n / 2) as f32) as usize
        })
        .collect();
    let mut rows: Vec<Vec<f32>> = Vec::new();
    let mut o = 0usize;
    while o + n <= mono.len() {
        let mut buf: Vec<Complex<f32>> = (0..n)
            .map(|i| {
                let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos();
                Complex::new(mono[o + i] * w, 0.0)
            })
            .collect();
        fft.process(&mut buf);
        let row: Vec<f32> = (0..bands)
            .map(|b| {
                let (a, z) = (edges[b].max(1), edges[b + 1].max(edges[b] + 1).min(n / 2));
                let e: f32 = buf[a..z].iter().map(|c| c.norm_sqr()).sum::<f32>() / (z - a) as f32;
                10.0 * (e + 1e-10).log10()
            })
            .collect();
        rows.push(row);
        o += hop;
    }
    let mut f = std::fs::File::create(csv).unwrap();
    for r in &rows {
        let line: Vec<String> = r.iter().map(|v| format!("{v:.1}")).collect();
        writeln!(f, "{}", line.join(",")).unwrap();
    }
    // Escalon: distancia media por banda entre 3 s antes y 3 s despues,
    // solo donde los dos lados tienen audio.
    let side = 6usize;
    let energy: Vec<f32> = rows.iter().map(|r| r.iter().sum::<f32>() / bands as f32).collect();
    let peak = energy.iter().cloned().fold(f32::MIN, f32::max);
    let mut best = (0.0f32, 0u64);
    for k in side..rows.len().saturating_sub(side) {
        let mean = |a: usize, b: usize| -> Vec<f32> {
            (0..bands)
                .map(|j| rows[a..b].iter().map(|r| r[j]).sum::<f32>() / (b - a) as f32)
                .collect()
        };
        let eb = energy[k - side..k].iter().sum::<f32>() / side as f32;
        let ea = energy[k..k + side].iter().sum::<f32>() / side as f32;
        if eb < peak - 30.0 || ea < peak - 30.0 {
            continue;
        }
        let (b, a) = (mean(k - side, k), mean(k, k + side));
        let d = b.iter().zip(&a).map(|(x, y)| (x - y).abs()).sum::<f32>() / bands as f32;
        if d > best.0 {
            best = (d, k as u64 * 500);
        }
    }
    best
}

#[test]
#[ignore]
fn dif29_arnes_reemplazo() {
    let jobs = std::fs::read_to_string(std::env::var("GMX_DIF29_JOBS").unwrap()).unwrap();
    let out = std::env::var("GMX_DIF29_OUT").unwrap();
    let raw_dir = std::env::var("GMX_DIF29_RAW").unwrap();
    let model = std::env::var("GMX_DIF29_MODEL").unwrap();
    let only_audit = std::env::var("GMX_DIF29_AUDIT").is_ok();
    std::fs::create_dir_all(&out).unwrap();
    let mut rep = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{out}/reporte.tsv"))
        .unwrap();
    for line in jobs.lines().filter(|l| !l.trim().is_empty()) {
        let c: Vec<&str> = line.split('\t').collect();
        let (id, name, orig) = (c[0], c[1], c[2]);
        let raw = format!("{raw_dir}/raw_{id}.m4a");
        let o_ms = decoded_duration_ms(orig).unwrap_or(0);
        let (om, orate) = mono_of(orig);
        let o_hits = crate::anti_splice::splice_scan(&om, orate);
        let (o_step, o_at) = spectro(&om, orate, &format!("{out}/{id}_orig.csv"));
        let raw_ms = decoded_duration_ms(&raw).unwrap_or(0);
        println!("DIF29 {id} ORIG {o_ms} ms hits={o_hits:?} escalon={o_step:.1}dB@{o_at} | YT {raw_ms} ms");
        if only_audit {
            continue;
        }
        let mp3 = format!("{out}/{name}.mp3");
        let k = format!("{out}/{name}_K.mp3");
        let t = std::time::Instant::now();
        let r1 = encode_to_mp3(raw.clone(), mp3.clone(), 320, true);
        let r2 = r1.clone().and_then(|_| master_rewrite(mp3.clone(), true, true, false, -1, -1).map(|_| true));
        let r3 = r2
            .clone()
            .and_then(|_| karaoke_separate(mp3.clone(), model.clone(), k.clone()));
        let status = match (&r1, &r2, &r3) {
            (Ok(_), Ok(_), Ok(_)) => "OK".to_string(),
            _ => format!("FALLO enc={r1:?} master={r2:?} k={r3:?}"),
        };
        let m_ms = decoded_duration_ms(&mp3).unwrap_or(0);
        let k_ms = decoded_duration_ms(&k).unwrap_or(0);
        let (mm, mrate) = mono_of(&mp3);
        let m_hits = crate::anti_splice::splice_scan(&mm, mrate);
        let (m_step, m_at) = spectro(&mm, mrate, &format!("{out}/{id}_new.csv"));
        let k_hits = if k_ms > 0 {
            let (km, krate) = mono_of(&k);
            crate::anti_splice::splice_scan(&km, krate)
        } else {
            Vec::new()
        };
        let marks = read_gmx_marks(mp3.clone());
        let tag = id3::Tag::read_from_path(&mp3).ok();
        let bpm = tag
            .as_ref()
            .and_then(|t| t.get("TBPM").and_then(|f| f.content().text().map(|s| s.to_string())))
            .unwrap_or_default();
        println!(
            "DIF29 {id} NUEVO {status} mp3={m_ms} ms K={k_ms} ms hits={m_hits:?} k_hits={k_hits:?} escalon={m_step:.1}dB@{m_at} bpm={bpm} trim={}/{} lufs={:.2} bpm_ok={} t={:?}",
            marks.trim_ms,
            marks.trim_tail_ms,
            marks.lufs,
            marks.bpm_ok,
            t.elapsed()
        );
        writeln!(
            rep,
            "{id}\t{name}\t{o_ms}\t{raw_ms}\t{m_ms}\t{k_ms}\t{}\t{}\t{}\t{m_step:.1}\t{o_step:.1}@{o_at}\t{status}",
            o_hits.len(),
            m_hits.len(),
            k_hits.len()
        )
        .unwrap();
    }
}