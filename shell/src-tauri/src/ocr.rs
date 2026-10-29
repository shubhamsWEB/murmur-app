//! Text in a picture, with Windows' own OCR (Windows.Media.Ocr, in the languages the person has set up): Murmur.exe
//! started again as `--ocr <picture>` prints the text and exits. The search engine (`murmur-engine index-service`,
//! which has no OCR of its own off the Mac) runs it for screenshots and photos, as `MURMUR_OCR` (helper.rs passes this
//! program there), so "the screenshot with the invoice number" and a photographed receipt are found by their words.
//! Nothing leaves the PC.

pub const ARGUMENT: &str = "--ocr";

/// `Murmur.exe --ocr <picture>`: the picture's text on standard output, a line per line of text. Exit code 0 (with no
/// output when there's no text), 2 for no picture given, 1 when it can't be read.
pub fn serve(args: &[String]) -> i32 {
    let Some(path) = args.first() else {
        eprintln!("ocr: which picture?");
        return 2;
    };
    match read(path) {
        Ok(text) => {
            use std::io::Write;
            let mut out = std::io::stdout().lock();
            if out.write_all(text.as_bytes()).and_then(|_| out.flush()).is_err() {
                return 1;
            }
            0
        }
        Err(error) => {
            eprintln!("ocr: {error}");
            1
        }
    }
}

#[cfg(windows)]
fn read(path: &str) -> Result<String, String> {
    use windows::core::HSTRING;
    use windows::Graphics::Imaging::{
        BitmapAlphaMode, BitmapDecoder, BitmapInterpolationMode, BitmapPixelFormat, BitmapTransform,
        ColorManagementMode, ExifOrientationMode,
    };
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::{FileAccessMode, StorageFile};
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

    let failed = |what: &str, error: windows::core::Error| format!("{what}: {}", error.message());
    // SAFETY: once, at the start of this process's only thread that uses WinRT.
    unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.map_err(|error| failed("WinRT", error))?;
    // No OCR language installed for the person's languages: nothing to read with (not an error worth more than that).
    let engine = OcrEngine::TryCreateFromUserProfileLanguages().map_err(|error| failed("no OCR language", error))?;
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))
        .and_then(|operation| operation.join())
        .map_err(|error| failed("can't open the picture", error))?;
    let stream = file.OpenAsync(FileAccessMode::Read).and_then(|operation| operation.join())
        .map_err(|error| failed("can't read the picture", error))?;
    let decoder = BitmapDecoder::CreateAsync(&stream).and_then(|operation| operation.join())
        .map_err(|error| failed("can't decode the picture", error))?;
    // The OCR engine takes pictures up to MaxImageDimension on their long side (2,600 pixels): bigger ones are scaled
    // down, turned the way the camera held them.
    let (width, height) = (decoder.PixelWidth().unwrap_or(0), decoder.PixelHeight().unwrap_or(0));
    if width == 0 || height == 0 {
        return Err("the picture is empty".into());
    }
    let most = OcrEngine::MaxImageDimension().unwrap_or(2600).max(1) as f64;
    let scale = (most / width.max(height) as f64).min(1.0);
    let transform = BitmapTransform::new().map_err(|error| failed("transform", error))?;
    let _ = transform.SetScaledWidth(((width as f64 * scale) as u32).max(1));
    let _ = transform.SetScaledHeight(((height as f64 * scale) as u32).max(1));
    let _ = transform.SetInterpolationMode(BitmapInterpolationMode::Fant);
    let bitmap = decoder
        .GetSoftwareBitmapTransformedAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied, &transform,
                                           ExifOrientationMode::RespectExifOrientation,
                                           ColorManagementMode::DoNotColorManage)
        .and_then(|operation| operation.join())
        .map_err(|error| failed("can't decode the picture", error))?;
    let result = engine.RecognizeAsync(&bitmap).and_then(|operation| operation.join())
        .map_err(|error| failed("OCR failed", error))?;
    let lines = result.Lines().map_err(|error| failed("OCR failed", error))?;
    let mut text = Vec::new();
    for index in 0..lines.Size().unwrap_or(0) {
        if let Ok(line) = lines.GetAt(index).and_then(|line| line.Text()) {
            let line = line.to_string();
            if !line.trim().is_empty() {
                text.push(line);
            }
        }
    }
    Ok(text.join("\n"))
}

#[cfg(not(windows))]
fn read(_path: &str) -> Result<String, String> {
    Err("OCR is only built in on Windows".into())
}

/// What the search engine's helpers get so they can read pictures' text: this program, on Windows.
pub fn helper_env() -> Option<(String, String)> {
    if !cfg!(windows) {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    Some(("MURMUR_OCR".to_string(), exe.display().to_string()))
}
