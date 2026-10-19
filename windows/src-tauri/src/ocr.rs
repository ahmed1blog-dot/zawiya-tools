//! Local OCR through Windows.Media.Ocr. Other platforms report a clear "unavailable" error.

#[cfg(windows)]
mod imp {
    use std::path::Path;
    use windows::core::HSTRING;
    use windows::Globalization::Language;
    use windows::Graphics::Imaging::BitmapDecoder;
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::{FileAccessMode, StorageFile};

    fn fail(e: windows::core::Error) -> String {
        format!("تعذر التعرف على النص / OCR failed: {}", e.message())
    }

    pub fn languages() -> Vec<String> {
        OcrEngine::AvailableRecognizerLanguages()
            .map(|list| list.into_iter().filter_map(|l| l.LanguageTag().ok()).map(|t| t.to_string()).collect())
            .unwrap_or_default()
    }

    pub fn max_dimension() -> u32 {
        OcrEngine::MaxImageDimension().unwrap_or(2600)
    }

    /// Tries Arabic (when its OCR pack is installed) and the user-profile languages, keeping the
    /// longer result, because a Windows OCR engine recognises one language at a time.
    pub fn recognize(png: &Path) -> Result<String, String> {
        let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(png.as_os_str()))
            .and_then(|op| op.join())
            .map_err(fail)?;
        let stream = file.OpenAsync(FileAccessMode::Read).and_then(|op| op.join()).map_err(fail)?;
        let decoder = BitmapDecoder::CreateAsync(&stream).and_then(|op| op.join()).map_err(fail)?;
        let bitmap = decoder.GetSoftwareBitmapAsync().and_then(|op| op.join()).map_err(fail)?;
        let mut engines = Vec::new();
        if let Ok(arabic) = Language::CreateLanguage(&HSTRING::from("ar")) {
            if OcrEngine::IsLanguageSupported(&arabic).unwrap_or(false) {
                engines.extend(OcrEngine::TryCreateFromLanguage(&arabic).ok());
            }
        }
        engines.extend(OcrEngine::TryCreateFromUserProfileLanguages().ok());
        if engines.is_empty() {
            return Err("لا توجد لغة OCR مثبتة في Windows / No Windows OCR language is installed.".into());
        }
        let mut best = String::new();
        for engine in engines {
            let text = engine
                .RecognizeAsync(&bitmap)
                .and_then(|op| op.join())
                .and_then(|r| r.Text())
                .map_err(fail)?
                .to_string();
            if text.trim().chars().count() > best.trim().chars().count() {
                best = text;
            }
        }
        Ok(best)
    }
}

#[cfg(not(windows))]
mod imp {
    use std::path::Path;
    pub fn languages() -> Vec<String> {
        Vec::new()
    }
    pub fn max_dimension() -> u32 {
        3000
    }
    pub fn recognize(_: &Path) -> Result<String, String> {
        Err("OCR غير متاح على هذا النظام / OCR is unavailable on this platform (Windows only).".into())
    }
}

pub use imp::{languages, max_dimension, recognize};
