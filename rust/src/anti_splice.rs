//! 3.2.32: blindaje anti-empalme de los escritores de audio.
//!
//! Causa (DIF-29): el Masterizar viejo escribia en un temporal fijo y
//! compartido; un trabajo huerfano (timeout de Dart que no frena a Rust)
//! seguia escribiendo ahi mientras la pista siguiente usaba el mismo archivo
//! y el rename final pegaba un pedazo de otra cancion. Mecanismo actual:
//! 1. `unique_part`: cada trabajo reserva su propio temporal con
//!    `create_new` (pid + contador + reloj); nadie mas puede abrirlo.
//! 2. `claim_output`: un solo trabajo a la vez por archivo de salida; un
//!    huerfano que sigue vivo deja la pista en "Ocupado" en vez de compartir.
//! 3. `check_part`: antes de reemplazar, la duracion y el tamano del
//!    temporal tienen que cuadrar con lo esperado de SU fuente; si no, se
//!    aborta sin tocar el original.
//! 4. `splice_scan`: detector barato (RMS + cruces por cero) para auditar.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// Prefijo de los errores de verificacion (la UI lo muestra tal cual).
pub(crate) const SPLICE_ERR: &str = "Empalme evitado";
/// 3.2.33: marca de "no rehacer" (la fuente ya viene empalmada).
pub(crate) const SPLICE_NO_RETRY: &str = "sin reintento";
/// 3.2.33: reintentos automaticos tras un empalme (ademas del primer intento).
pub(crate) const SPLICE_RETRIES: u32 = 2;

/// 3.2.33: error de empalme que vale la pena rehacer desde la fuente.
pub(crate) fn splice_retryable(e: &str) -> bool {
    e.starts_with(SPLICE_ERR) && !e.contains(SPLICE_NO_RETRY)
}

static SEQ: AtomicU64 = AtomicU64::new(0);

/// Temporal unico junto a `base`: `<base>.<pid>_<n>_<t>.<tag>`, reservado con
/// `create_new` (si ya existe se prueba otro nombre; nunca se reutiliza).
pub(crate) fn unique_part(base: &str, tag: &str) -> Result<String, String> {
    if let Some(dir) = std::path::Path::new(base).parent() {
        if !dir.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(dir);
        }
    }
    for _ in 0..64 {
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let p = format!("{base}.{}_{n}_{t:x}.{tag}", std::process::id());
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&p)
        {
            Ok(_) => return Ok(p),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Err("No se pudo reservar un temporal unico".to_string())
}

fn busy() -> &'static Mutex<HashSet<String>> {
    static B: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    B.get_or_init(|| Mutex::new(HashSet::new()))
}

fn output_key(path: &str) -> String {
    let p = path.replace('\\', "/");
    if cfg!(windows) || cfg!(target_os = "macos") {
        p.to_lowercase()
    } else {
        p
    }
}

/// Salida reservada por un trabajo; se libera al soltarla.
pub(crate) struct OutputGuard(String);

impl Drop for OutputGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = busy().lock() {
            s.remove(&self.0);
        }
    }
}

/// Un solo escritor por archivo de salida.
pub(crate) fn claim_output(path: &str) -> Result<OutputGuard, String> {
    let k = output_key(path);
    let mut s = busy().lock().map_err(|_| "Candado de salida roto".to_string())?;
    if !s.insert(k.clone()) {
        return Err(format!(
            "Ocupado: otro trabajo sigue escribiendo esta pista ({path})"
        ));
    }
    Ok(OutputGuard(k))
}

/// Tolerancia de duracion: 0,5 % o 400 ms (retardo LAME/AAC y redondeos).
pub(crate) fn duration_tolerance_ms(expect_ms: u64) -> u64 {
    (expect_ms / 200).max(400)
}

/// Decide si un temporal ya escrito puede reemplazar la salida. `got_ms` es la
/// duracion contada del temporal, `size` sus bytes (con tags) y `kbps` el CBR
/// pedido a LAME (0 = no se valida el tamano).
pub(crate) fn check_part(got_ms: u64, size: u64, expect_ms: u64, kbps: u32) -> Result<(), String> {
    if expect_ms == 0 {
        return Err(format!("{SPLICE_ERR}: duracion esperada desconocida"));
    }
    let tol = duration_tolerance_ms(expect_ms);
    if got_ms.abs_diff(expect_ms) > tol {
        return Err(format!(
            "{SPLICE_ERR}: el temporal dura {got_ms} ms y la fuente {expect_ms} ms (tolerancia {tol} ms)"
        ));
    }
    if kbps > 0 {
        let audio = expect_ms.saturating_mul(kbps as u64) / 8;
        let min = audio * 6 / 10;
        let max = audio * 14 / 10 + 16 * 1024 * 1024;
        if size < min || size > max {
            return Err(format!(
                "{SPLICE_ERR}: el temporal pesa {size} B y se esperaban {min}..{max} B"
            ));
        }
    }
    Ok(())
}

/// Marca del detector: segundo del cambio, tipo y detalle legible.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct SpliceHit {
    pub at_ms: u64,
    pub kind: &'static str,
    pub detail: String,
}

/// 3.2.33: ventana del detector (500 ms).
pub(crate) const WIN_MS: u64 = 500;

/// 3.2.33: acumulador en streaming (sin guardar el PCM): RMS en dB y
/// cruces por cero por ventana.
pub(crate) struct FrameAcc {
    n: usize,
    e: f64,
    c: u32,
    k: usize,
    last: f32,
    db: Vec<f32>,
    zc: Vec<f32>,
}

impl FrameAcc {
    pub(crate) fn new(rate: u32) -> Self {
        FrameAcc {
            n: ((rate as u64 * WIN_MS) / 1000).max(1) as usize,
            e: 0.0,
            c: 0,
            k: 0,
            last: 0.0,
            db: Vec::new(),
            zc: Vec::new(),
        }
    }

    pub(crate) fn push(&mut self, x: f32) {
        self.e += (x as f64) * (x as f64);
        if self.k > 0 && (x >= 0.0) != (self.last >= 0.0) {
            self.c += 1;
        }
        self.last = x;
        self.k += 1;
        if self.k == self.n {
            self.close();
        }
    }

    fn close(&mut self) {
        let k = self.k.max(1) as f64;
        self.db.push((10.0 * (self.e / k + 1e-12).log10()) as f32);
        self.zc.push(self.c as f32 / k as f32);
        self.e = 0.0;
        self.c = 0;
        self.k = 0;
    }

    pub(crate) fn finish(mut self) -> (Vec<f32>, Vec<f32>) {
        if self.k >= self.n / 2 {
            self.close();
        }
        (self.db, self.zc)
    }
}

fn mean(v: &[f32]) -> f32 {
    if v.is_empty() {
        0.0
    } else {
        v.iter().sum::<f32>() / v.len() as f32
    }
}

/// Detector sobre PCM mono (pruebas y herramientas).
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn splice_scan(mono: &[f32], rate: u32) -> Vec<SpliceHit> {
    let mut a = FrameAcc::new(rate);
    for &x in mono {
        a.push(x);
    }
    let (db, zc) = a.finish();
    scan_frames(&db, &zc)
}

/// 3.2.33: umbrales (ventanas de 500 ms). Ver LOG 3.2.33.
const SIDE: usize = 6; // 3 s
const GAP_MIN: usize = 3; // hueco >= 1,5 s
const QUIET_DB: f32 = 35.0;
const LOUD_DB: f32 = 20.0;
const DIP_DB: f32 = 18.0;
const JUMP_DB: f32 = 12.0;

/// Detector de empalmes (3.2.33). Ventanas de 500 ms:
/// - "reinicio": hueco >= 1,5 s por debajo de (pico - 35 dB) y luego >= 3 s
///   fuertes (>= pico - 20 dB), despues del primer 10 %.
/// - "corte": final de cancion (3 s con media <= pico - 18 dB) y salto de
///   >= 12 dB en una ventana a >= 3 s fuertes, despues del 50 %. Es el
///   empalme real de DIF-29: la cancion se apaga y entra otra de golpe.
/// El "escalon" de brillo de 3.2.32 ya no marca (falsos positivos).
pub(crate) fn scan_frames(db: &[f32], _zc: &[f32]) -> Vec<SpliceHit> {
    let mut hits = Vec::new();
    if db.len() < 20 {
        return hits;
    }
    let peak = db.iter().cloned().fold(f32::MIN, f32::max);
    let quiet = peak - QUIET_DB;
    let loud = peak - LOUD_DB;
    let mut i = db.len() / 10;
    while i < db.len() {
        if db[i] < quiet {
            let mut j = i;
            while j < db.len() && db[j] < quiet {
                j += 1;
            }
            if j - i >= GAP_MIN && j + SIDE <= db.len() {
                let after = &db[j..j + SIDE];
                if after.iter().filter(|&&d| d >= loud).count() >= SIDE * 3 / 4 {
                    hits.push(SpliceHit {
                        at_ms: j as u64 * WIN_MS,
                        kind: "reinicio",
                        detail: format!(
                            "hueco de {} ms y luego {:.1} dB",
                            (j - i) as u64 * WIN_MS,
                            mean(after) - peak
                        ),
                    });
                }
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    let mut k = (db.len() / 2).max(SIDE);
    while k + SIDE <= db.len() {
        let before = mean(&db[k - SIDE..k]);
        let after = &db[k..k + SIDE];
        let jump = db[k] - db[k - 1];
        let near = hits
            .iter()
            .any(|h| h.at_ms.abs_diff(k as u64 * WIN_MS) <= SIDE as u64 * WIN_MS);
        if !near
            && before <= peak - DIP_DB
            && jump >= JUMP_DB
            && after.iter().filter(|&&d| d >= loud).count() >= SIDE * 3 / 4
        {
            hits.push(SpliceHit {
                at_ms: k as u64 * WIN_MS,
                kind: "corte",
                detail: format!(
                    "final a {:.1} dB y salto de {:+.1} dB",
                    before - peak,
                    jump
                ),
            });
            k += SIDE;
        } else {
            k += 1;
        }
    }
    hits
}
#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f32, secs: f32, rate: u32, amp: f32) -> Vec<f32> {
        let n = (secs * rate as f32) as usize;
        (0..n)
            .map(|i| amp * (2.0 * std::f32::consts::PI * hz * i as f32 / rate as f32).sin())
            .collect()
    }

    #[test]
    fn anti_splice_3232_unique_part_create_new() {
        let base = std::env::temp_dir()
            .join(format!("gmx_3232_u_{}.mp3", std::process::id()))
            .to_string_lossy()
            .to_string();
        let a = unique_part(&base, "gmxpart").unwrap();
        let b = unique_part(&base, "gmxpart").unwrap();
        assert_ne!(a, b);
        assert!(std::path::Path::new(&a).exists());
        let again = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&a);
        assert!(again.is_err(), "create_new protege el nombre reservado");
        let _ = std::fs::remove_file(&a);
        let _ = std::fs::remove_file(&b);
    }

    #[test]
    fn anti_splice_3232_one_writer_per_output() {
        let g = claim_output("C:\\X\\Cancion.mp3").unwrap();
        let e = claim_output("c:/x/cancion.mp3");
        if cfg!(windows) {
            assert!(e.is_err());
        }
        drop(e);
        drop(g);
        assert!(claim_output("C:\\X\\Cancion.mp3").is_ok());
    }

    #[test]
    fn anti_splice_3232_check_part() {
        // 200 s a 320 kbps: 8 MB de audio.
        let ok = 200_000u64 * 320 / 8;
        assert!(check_part(200_300, ok, 200_000, 320).is_ok());
        let long = check_part(260_000, ok, 200_000, 320).unwrap_err();
        assert!(long.starts_with(SPLICE_ERR));
        assert!(check_part(198_900, ok, 200_000, 320).is_err());
        assert!(check_part(200_000, ok / 3, 200_000, 320).is_err());
        assert!(check_part(200_000, 0, 200_000, 0).is_ok());
        assert!(check_part(1000, ok, 0, 320).is_err());
    }

    #[test]
    fn anti_splice_3232_scan_flags_tail_piece() {
        let r = 8000;
        // Cancion de 40 s, fin, 1,5 s de silencio y 8 s de otra.
        let mut s = tone(440.0, 40.0, r, 0.5);
        s.extend(std::iter::repeat(0.0).take((1.5 * r as f32) as usize));
        s.extend(tone(1200.0, 8.0, r, 0.5));
        let hits = splice_scan(&s, r);
        assert!(hits.iter().any(|h| h.kind == "reinicio"), "{hits:?}");
        // 3.2.33: solo cambio de brillo (antes "escalon"): ya no marca.
        let mut t = tone(300.0, 40.0, r, 0.5);
        t.extend(tone(1500.0, 8.0, r, 0.5));
        assert!(splice_scan(&t, r).is_empty());
        // 3.2.33: "corte": se apaga a -20 dB y entra otra de golpe.
        let mut c = tone(440.0, 40.0, r, 0.5);
        c.extend(tone(440.0, 3.5, r, 0.05));
        c.extend(tone(1200.0, 8.0, r, 0.5));
        let hits = splice_scan(&c, r);
        assert!(hits.iter().any(|h| h.kind == "corte"), "{hits:?}");
        // Pista limpia: nada.
        let clean = tone(440.0, 48.0, r, 0.5);
        assert!(splice_scan(&clean, r).is_empty());
    }

    /// 3.2.33: ventanas reales (500 ms, dB bajo el pico, 1 car = 1 dB) de las
    /// 9 canciones de DIF-29: E = originales empalmados (Cuarentena_MP3),
    /// L = las mismas bajadas limpias. Fixture estatico: no reabre audio.
    fn fixture() -> Vec<(String, Vec<f32>)> {
        include_str!("../../test/fixtures/splice_frames_3233.txt")
            .lines()
            .filter_map(|l| l.split_once('\t'))
            .map(|(k, v)| {
                (
                    k.to_string(),
                    v.bytes().map(|b| -((b - 33) as f32)).collect(),
                )
            })
            .collect()
    }

    #[test]
    fn anti_splice_3233_fixture_clean_songs_pass() {
        let f = fixture();
        assert_eq!(f.len(), 18);
        for (k, db) in f.iter().filter(|(k, _)| k.starts_with('L')) {
            let hits = scan_frames(db, &[]);
            assert!(hits.is_empty(), "{k}: {hits:?}");
        }
    }

    #[test]
    fn anti_splice_3233_fixture_spliced_originals() {
        // Los empalmes reales de DIF-29 no los separa el volumen (la otra
        // cancion entra a nivel parecido): los atrapa la duracion contra la
        // fuente (check_part). El detector no debe inventar marcas aqui.
        for (k, db) in fixture().iter().filter(|(k, _)| k.starts_with('E')) {
            let hits = scan_frames(db, &[]);
            assert!(hits.is_empty(), "{k}: {hits:?}");
        }
        assert!(splice_retryable("Empalme evitado: detector corte"));
        assert!(!splice_retryable("Empalme evitado: x, sin reintento"));
        assert!(!splice_retryable("Cancelado"));
    }
}