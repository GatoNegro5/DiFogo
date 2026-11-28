//! Invocador suelto de `master_rewrite` (DIF-40).
//!
//! Usa el mismo pipeline que la app: temporal unico, `verify_part`,
//! `splice_gate` y reemplazo. Si el gate marca, el original queda intacto.
//! No pasa por el arnes DIF-29 (ese mezcla encode YT + decode y puede
//! abortar antes de escribir).
//!
//! Uso:
//!   gmx_master --in <mp3>
//!   gmx_master --in <mp3> --quarantine <dir>
//!   gmx_master --in <mp3> --karaoke-out <pista_K.mp3> --model <modelo.onnx>
//!
//! Por defecto aplica recorte y LUFS (-14), como Masterizar en la app.
//! Activa `GMX_HEADLESS=1` si no viene en el entorno.

use rust_lib_gatomix_player::api::core_dsp::{
    karaoke_separate, master_rewrite, read_gmx_marks,
};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

fn arg_val(args: &[String], key: &str) -> Option<String> {
    let pref = format!("{key}=");
    let mut i = 0;
    while i < args.len() {
        if args[i] == key {
            return args.get(i + 1).cloned();
        }
        if let Some(rest) = args[i].strip_prefix(&pref) {
            if !rest.is_empty() {
                return Some(rest.to_string());
            }
        }
        i += 1;
    }
    None
}

fn flag(args: &[String], key: &str) -> bool {
    args.iter().any(|a| a == key)
}

fn usage() -> ! {
    eprintln!(
        "gmx_master --in <mp3> [--quarantine <dir>] [--no-trim] [--no-lufs]\n\
         [--karaoke-out <_K.mp3> --model <onnx>]\n\
         Pipeline: master_rewrite (verify_part + splice_gate). GMX_HEADLESS=1."
    );
    process::exit(2);
}

fn copy_quarantine(src: &Path, dir: &Path) -> Result<PathBuf, String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let name = src
        .file_name()
        .ok_or_else(|| "sin nombre".to_string())?;
    let dest = dir.join(name);
    let dest = if dest.exists() {
        let stem = src.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
        let ext = src.extension().and_then(|s| s.to_str()).unwrap_or("mp3");
        dir.join(format!("{stem}.{}.{ext}", std::process::id()))
    } else {
        dest
    };
    fs::copy(src, &dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

fn main() {
    if env::var_os("GMX_HEADLESS").is_none() {
        env::set_var("GMX_HEADLESS", "1");
    }
    let args: Vec<String> = env::args().skip(1).collect();
    if flag(&args, "--help") || flag(&args, "-h") {
        usage();
    }
    let input = match arg_val(&args, "--in") {
        Some(p) if !p.is_empty() => p,
        _ => usage(),
    };
    let in_path = Path::new(&input);
    if !in_path.is_file() {
        eprintln!("gmx_master: no existe --in {input}");
        process::exit(1);
    }
    if let Some(dir) = arg_val(&args, "--quarantine") {
        match copy_quarantine(in_path, Path::new(&dir)) {
            Ok(dest) => eprintln!("gmx_master: cuarentena {}", dest.display()),
            Err(e) => {
                eprintln!("gmx_master: cuarentena fallo: {e}");
                process::exit(1);
            }
        }
    }
    let do_trim = !flag(&args, "--no-trim");
    let do_lufs = !flag(&args, "--no-lufs");
    eprintln!("gmx_master: rewrite {input} trim={do_trim} lufs={do_lufs}");
    match master_rewrite(input.clone(), do_trim, do_lufs, false, -1, -1) {
        Ok(r) => {
            let marks = read_gmx_marks(input.clone());
            println!(
                "OK rewritten={} bpm={:.2} lufs={:.2} lufs_applied={} trim={}/{} lead={} tail={} kbps={} residual={} gmx_lufs={:.2} gmx_lufs_done={}",
                r.rewritten,
                r.bpm,
                r.lufs,
                r.lufs_applied,
                r.trim_head_ms,
                r.trim_tail_ms,
                r.lead_ms,
                r.tail_ms,
                r.bitrate_kbps,
                r.residual_ms,
                marks.lufs,
                marks.lufs_done,
            );
        }
        Err(e) => {
            eprintln!("gmx_master: FALLO master_rewrite: {e}");
            process::exit(1);
        }
    }

    if let Some(kout) = arg_val(&args, "--karaoke-out") {
        let model = match arg_val(&args, "--model") {
            Some(m) if !m.is_empty() => m,
            _ => {
                eprintln!("gmx_master: --karaoke-out requiere --model");
                process::exit(1);
            }
        };
        if !Path::new(&model).is_file() {
            eprintln!("gmx_master: no existe --model {model}");
            process::exit(1);
        }
        eprintln!("gmx_master: karaoke {kout}");
        match karaoke_separate(input, model, kout) {
            Ok(ok) => println!("OK karaoke={ok}"),
            Err(e) => {
                eprintln!("gmx_master: FALLO karaoke_separate: {e}");
                process::exit(1);
            }
        }
    }
}