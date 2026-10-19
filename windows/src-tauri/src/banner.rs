//! Remote announcement banner (announcements/banner.json in the public repo), strictly validated.

use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const URL: &str = "https://raw.githubusercontent.com/ahmed1blog-dot/zawiya-tools/main/announcements/banner.json";
pub const IMAGE_PREFIX: &str = "https://raw.githubusercontent.com/ahmed1blog-dot/zawiya-tools/main/announcements/";
const MAX_JSON: usize = 64 * 1024;
const MAX_IMAGE: usize = 1024 * 1024;

// Unknown fields are ignored (as on Mac) so a future schema field never hides the banner.
#[derive(Deserialize)]
struct Raw {
    version: u32,
    enabled: bool,
    id: String,
    title_ar: String,
    title_en: String,
    body_ar: String,
    body_en: String,
    cta_ar: String,
    cta_en: String,
    url: String,
    #[serde(default)]
    image: String,
    expires: String,
    platforms: Vec<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Banner {
    pub id: String,
    pub title_ar: String,
    pub title_en: String,
    pub body_ar: String,
    pub body_en: String,
    pub cta_ar: String,
    pub cta_en: String,
    pub url: String,
    pub image: String,
    /// `data:` URL filled after a successful, size-limited image fetch.
    pub image_data: Option<String>,
}

/// `(year, month, day)` in UTC for the current time.
pub fn today() -> (i64, u32, u32) {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    civil_from_days((secs / 86_400) as i64)
}

/// Howard Hinnant's days→civil algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn parse_date(s: &str) -> Option<(i64, u32, u32)> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let (y, m, d) = (s[..4].parse().ok()?, s[5..7].parse().ok()?, s[8..].parse().ok()?);
    ((1..=12).contains(&m) && (1..=31).contains(&d)).then_some((y, m, d))
}

fn is_https(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|u| {
        u.scheme() == "https"
            && u.host_str().is_some_and(|h| !h.is_empty())
            && u.username().is_empty()
            && u.password().is_none()
    })
}

fn short(s: &str, max: usize) -> bool {
    s.chars().count() <= max && !s.chars().any(char::is_control)
}

/// `Ok(None)`: well-formed but not to be shown (disabled, expired, other platform).
/// `Err`: malformed or violates a rule; never displayed.
pub fn validate(body: &[u8], today: (i64, u32, u32)) -> Result<Option<Banner>, String> {
    if body.len() > MAX_JSON {
        return Err("too large".into());
    }
    let raw: Raw = serde_json::from_slice(body).map_err(|e| e.to_string())?;
    if raw.version != 1 {
        return Err("version".into());
    }
    let id_ok =
        (1..=64).contains(&raw.id.len()) && raw.id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b));
    let texts = [
        (&raw.title_ar, 60),
        (&raw.title_en, 60),
        (&raw.body_ar, 160),
        (&raw.body_en, 160),
        (&raw.cta_ar, 24),
        (&raw.cta_en, 24),
    ];
    if !id_ok
        || !texts.iter().all(|(s, max)| short(s, *max))
        || raw.title_ar.trim().is_empty()
        || raw.title_en.trim().is_empty()
    {
        return Err("text".into());
    }
    if !is_https(&raw.url) || raw.url.len() > 2048 {
        return Err("url".into());
    }
    if !raw.image.is_empty() {
        let name = raw.image.strip_prefix(IMAGE_PREFIX).unwrap_or("");
        let lower = name.to_ascii_lowercase();
        let ok = !name.is_empty()
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./".contains(&b))
            && !name.contains("..")
            && (lower.ends_with(".png") || lower.ends_with(".jpg") || lower.ends_with(".jpeg"));
        if !ok {
            return Err("image".into());
        }
    }
    let expires = parse_date(&raw.expires).ok_or("expires")?;
    if raw.platforms.len() > 8 || raw.platforms.iter().any(|p| p != "mac" && p != "windows") {
        return Err("platforms".into());
    }
    if !raw.enabled || !raw.platforms.iter().any(|p| p == "windows") || today > expires {
        return Ok(None);
    }
    Ok(Some(Banner {
        id: raw.id,
        title_ar: raw.title_ar,
        title_en: raw.title_en,
        body_ar: raw.body_ar,
        body_en: raw.body_en,
        cta_ar: raw.cta_ar,
        cta_en: raw.cta_en,
        url: raw.url,
        image: raw.image,
        image_data: None,
    }))
}

fn client(version: &str) -> Result<reqwest::Client, String> {
    // Plain GET with only a product User-Agent: no cookies, no custom headers, no redirects.
    reqwest::Client::builder()
        .user_agent(format!("ZawiyaTools/{version}"))
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())
}

async fn get_limited(client: &reqwest::Client, url: &str, limit: usize) -> Result<Vec<u8>, String> {
    let mut resp = client.get(url).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(resp.status().to_string());
    }
    if resp.content_length().is_some_and(|n| n as usize > limit) {
        return Err("too large".into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
        body.extend_from_slice(&chunk);
        if body.len() > limit {
            return Err("too large".into());
        }
    }
    Ok(body)
}

/// Network fetch. `Ok(raw json)` only for a 2xx response within limits.
pub async fn fetch(version: &str) -> Result<Vec<u8>, String> {
    get_limited(&client(version)?, URL, MAX_JSON).await
}

/// Downloads the optional image (≤1MB, PNG/JPEG magic checked) into a data URL.
pub async fn attach_image(banner: &mut Banner, version: &str) {
    use base64::Engine;
    if banner.image.is_empty() {
        return;
    }
    let Ok(client) = client(version) else { return };
    let Ok(data) = get_limited(&client, &banner.image, MAX_IMAGE).await else { return };
    let mime = if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else {
        return;
    };
    banner.image_data = Some(format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(data)));
}

#[cfg(test)]
mod tests {
    use super::*;

    const TODAY: (i64, u32, u32) = (2026, 10, 19);

    fn sample() -> serde_json::Value {
        serde_json::from_str(include_str!("../../../announcements/banner.json")).unwrap()
    }
    fn check(v: &serde_json::Value) -> Result<Option<Banner>, String> {
        validate(v.to_string().as_bytes(), TODAY)
    }

    #[test]
    fn repo_banner_is_valid() {
        let b = check(&sample()).unwrap().unwrap();
        assert_eq!(b.url, "https://instagram.com/qqad7");
        assert!(b.image_data.is_none());
    }

    #[test]
    fn rejects_or_hides_bad_banners() {
        let edit = |f: &dyn Fn(&mut serde_json::Value)| {
            let mut v = sample();
            f(&mut v);
            check(&v)
        };
        // Hidden (well-formed): expired, disabled, other platform.
        assert_eq!(edit(&|v| v["expires"] = "2026-10-18".into()), Ok(None));
        assert!(edit(&|v| v["expires"] = "2026-10-19".into()).unwrap().is_some());
        assert_eq!(edit(&|v| v["enabled"] = false.into()), Ok(None));
        assert_eq!(edit(&|v| v["platforms"] = serde_json::json!(["mac"])), Ok(None));
        // Rejected.
        assert!(edit(&|v| v["url"] = "http://instagram.com/qqad7".into()).is_err());
        assert!(edit(&|v| v["url"] = "javascript:alert(1)".into()).is_err());
        assert!(edit(&|v| v["image"] = "https://evil.example/announcements/a.png".into()).is_err());
        assert!(edit(&|v| v["image"] = format!("{IMAGE_PREFIX}../x.png").into()).is_err());
        assert!(edit(&|v| v["image"] = format!("{IMAGE_PREFIX}a.svg").into()).is_err());
        assert!(edit(&|v| v["image"] = format!("{IMAGE_PREFIX}promo.png").into()).unwrap().is_some());
        assert!(edit(&|v| v["title_en"] = "x".repeat(61).into()).is_err());
        assert!(edit(&|v| v["body_ar"] = "ب".repeat(161).into()).is_err());
        assert!(edit(&|v| v["body_ar"] = "ب".repeat(160).into()).unwrap().is_some());
        assert!(edit(&|v| v["cta_en"] = "y".repeat(25).into()).is_err());
        assert!(edit(&|v| v["id"] = "a b".into()).is_err());
        assert!(edit(&|v| v["version"] = 2.into()).is_err());
        assert!(edit(&|v| v["expires"] = "31-12-2027".into()).is_err());
        assert!(edit(&|v| v["extra"] = 1.into()).is_ok());
        assert!(validate(&vec![b' '; MAX_JSON + 1], TODAY).is_err());
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_745), (2026, 10, 19));
        assert_eq!(civil_from_days(11_016), (2000, 2, 29));
    }
}
