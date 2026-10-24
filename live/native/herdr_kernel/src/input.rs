//! Key, mouse, and focus encoders over ghostty. The encoders live in their own mutex on `Vt`
//! (never the core lock) and are reconfigured from the terminal after each write and resize,
//! so `encode_*` never waits on parsing.

use ghostty_vt::{ffi, FocusEvent, KeyEncoder, KeyEvent, MouseEncoder, MouseEvent, Terminal};

use crate::vt::{lock, Vt};

/// DEC private mode 1003.
const MODE_MOUSE_ANY_MOTION: u16 = 1003;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub super_: bool,
}

impl Mods {
    fn raw(self) -> u16 {
        [
            (self.shift, ghostty_vt::MOD_SHIFT),
            (self.ctrl, ghostty_vt::MOD_CTRL),
            (self.alt, ghostty_vt::MOD_ALT),
            (self.super_, ghostty_vt::MOD_SUPER),
        ]
        .iter()
        .filter(|(on, _)| *on)
        .fold(0, |a, (_, m)| a | m)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Press,
    Release,
    Repeat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedKey {
    Enter,
    Tab,
    Backspace,
    Escape,
    Space,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    /// `F(1)..=F(24)`.
    F(u8),
    /// Keypad digit `Kp(0)..=Kp(9)`.
    Kp(u8),
    KpEnter,
    KpAdd,
    KpSubtract,
    KpMultiply,
    KpDivide,
    KpDecimal,
    KpEqual,
}

impl NamedKey {
    /// Parses the lowercase BEAM atom name (`"page_up"`, `"f12"`, `"kp_3"`).
    pub fn from_name(name: &str) -> Option<NamedKey> {
        use NamedKey::*;
        let num = |p: &str, min: u8, max: u8| {
            let digits = name.strip_prefix(p)?;
            let n = digits.parse::<u8>().ok()?;
            (n.to_string() == digits && (min..=max).contains(&n)).then_some(n)
        };
        if let Some(n) = num("f", 1, 24) {
            return Some(F(n));
        }
        if let Some(n) = num("kp_", 0, 9) {
            return Some(Kp(n));
        }
        Some(match name {
            "enter" => Enter,
            "tab" => Tab,
            "backspace" => Backspace,
            "escape" => Escape,
            "space" => Space,
            "up" => Up,
            "down" => Down,
            "left" => Left,
            "right" => Right,
            "home" => Home,
            "end" => End,
            "page_up" => PageUp,
            "page_down" => PageDown,
            "insert" => Insert,
            "delete" => Delete,
            "kp_enter" => KpEnter,
            "kp_add" => KpAdd,
            "kp_subtract" => KpSubtract,
            "kp_multiply" => KpMultiply,
            "kp_divide" => KpDivide,
            "kp_decimal" => KpDecimal,
            "kp_equal" => KpEqual,
            _ => return None,
        })
    }

    fn raw(self) -> ffi::GhosttyKey {
        use ffi::*;
        use NamedKey::*;
        match self {
            Enter => GhosttyKey_GHOSTTY_KEY_ENTER,
            Tab => GhosttyKey_GHOSTTY_KEY_TAB,
            Backspace => GhosttyKey_GHOSTTY_KEY_BACKSPACE,
            Escape => GhosttyKey_GHOSTTY_KEY_ESCAPE,
            Space => GhosttyKey_GHOSTTY_KEY_SPACE,
            Up => GhosttyKey_GHOSTTY_KEY_ARROW_UP,
            Down => GhosttyKey_GHOSTTY_KEY_ARROW_DOWN,
            Left => GhosttyKey_GHOSTTY_KEY_ARROW_LEFT,
            Right => GhosttyKey_GHOSTTY_KEY_ARROW_RIGHT,
            Home => GhosttyKey_GHOSTTY_KEY_HOME,
            End => GhosttyKey_GHOSTTY_KEY_END,
            PageUp => GhosttyKey_GHOSTTY_KEY_PAGE_UP,
            PageDown => GhosttyKey_GHOSTTY_KEY_PAGE_DOWN,
            Insert => GhosttyKey_GHOSTTY_KEY_INSERT,
            Delete => GhosttyKey_GHOSTTY_KEY_DELETE,
            // F1..F24 and the keypad digits are contiguous in the ghostty key table.
            F(n) => GhosttyKey_GHOSTTY_KEY_F1 + (n.clamp(1, 24) - 1) as GhosttyKey,
            Kp(n) => GhosttyKey_GHOSTTY_KEY_NUMPAD_0 + n.min(9) as GhosttyKey,
            KpEnter => GhosttyKey_GHOSTTY_KEY_NUMPAD_ENTER,
            KpAdd => GhosttyKey_GHOSTTY_KEY_NUMPAD_ADD,
            KpSubtract => GhosttyKey_GHOSTTY_KEY_NUMPAD_SUBTRACT,
            KpMultiply => GhosttyKey_GHOSTTY_KEY_NUMPAD_MULTIPLY,
            KpDivide => GhosttyKey_GHOSTTY_KEY_NUMPAD_DIVIDE,
            KpDecimal => GhosttyKey_GHOSTTY_KEY_NUMPAD_DECIMAL,
            KpEqual => GhosttyKey_GHOSTTY_KEY_NUMPAD_EQUAL,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    Char(String),
    Named(NamedKey),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyInput {
    pub key: Key,
    pub mods: Mods,
    pub event: KeyAction,
    /// Text the key produced on the user's layout. Defaults to the character itself.
    pub text: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseKind {
    Press,
    Release,
    Move,
    Drag,
    Scroll,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MouseInput {
    pub kind: MouseKind,
    pub button: Option<MouseButton>,
    pub x: u16,
    pub y: u16,
    pub mods: Mods,
    /// Pixel position; `None` means the centre of cell `(x, y)`.
    pub px: Option<(f32, f32)>,
}

fn char_key(c: char) -> ffi::GhosttyKey {
    use ffi::*;
    match c {
        'a'..='z' => GhosttyKey_GHOSTTY_KEY_A + (c as u32 - 'a' as u32) as GhosttyKey,
        '0'..='9' => GhosttyKey_GHOSTTY_KEY_DIGIT_0 + (c as u32 - '0' as u32) as GhosttyKey,
        '`' => GhosttyKey_GHOSTTY_KEY_BACKQUOTE,
        '\\' => GhosttyKey_GHOSTTY_KEY_BACKSLASH,
        '[' => GhosttyKey_GHOSTTY_KEY_BRACKET_LEFT,
        ']' => GhosttyKey_GHOSTTY_KEY_BRACKET_RIGHT,
        ',' => GhosttyKey_GHOSTTY_KEY_COMMA,
        '=' => GhosttyKey_GHOSTTY_KEY_EQUAL,
        '-' => GhosttyKey_GHOSTTY_KEY_MINUS,
        '.' => GhosttyKey_GHOSTTY_KEY_PERIOD,
        '\'' => GhosttyKey_GHOSTTY_KEY_QUOTE,
        ';' => GhosttyKey_GHOSTTY_KEY_SEMICOLON,
        '/' => GhosttyKey_GHOSTTY_KEY_SLASH,
        ' ' => GhosttyKey_GHOSTTY_KEY_SPACE,
        _ => GhosttyKey_GHOSTTY_KEY_UNIDENTIFIED,
    }
}

fn key_event(k: &KeyInput) -> Option<KeyEvent> {
    let mut ev = KeyEvent::new().ok()?;
    ev.set_action(match k.event {
        KeyAction::Press => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_PRESS,
        KeyAction::Release => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_RELEASE,
        KeyAction::Repeat => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_REPEAT,
    });
    let mut mods = k.mods.raw();
    match &k.key {
        Key::Named(n) => {
            ev.set_key(n.raw());
            let text = match (&k.text, n) {
                (Some(t), _) => Some(t.as_str()),
                (None, NamedKey::Space) => Some(" "),
                _ => None,
            };
            if let Some(t) = text {
                ev.set_utf8(t);
            }
        }
        Key::Char(s) => {
            let mut chars = s.chars();
            let single = match (chars.next(), chars.next()) {
                (Some(c), None) => Some(c),
                _ => None,
            };
            // An uppercase letter is its lowercase key plus Shift, on every layout.
            let base = single.map(|c| {
                let mut l = c.to_lowercase();
                match (l.next(), l.next()) {
                    (Some(l), None) if c.is_uppercase() => l,
                    _ => c,
                }
            });
            if let (Some(c), Some(b)) = (single, base) {
                if c != b {
                    mods |= ghostty_vt::MOD_SHIFT;
                }
                ev.set_key(char_key(b));
                ev.set_unshifted_codepoint(b as u32);
            }
            let text = k
                .text
                .as_deref()
                .or((!k.mods.ctrl && !k.mods.super_).then_some(s.as_str()))
                .filter(|t| !t.is_empty() && !t.chars().any(char::is_control));
            if let Some(t) = text {
                if mods & ghostty_vt::MOD_SHIFT != 0 && base.map(String::from).as_deref() != Some(t)
                {
                    ev.set_consumed_mods(ghostty_vt::MOD_SHIFT);
                }
                ev.set_utf8(t);
            }
        }
    }
    ev.set_mods(mods);
    Some(ev)
}

pub(crate) struct Encoders {
    key: KeyEncoder,
    mouse: MouseEncoder,
    tracking: bool,
    any_motion: bool,
    focus: bool,
    sgr_pixels: bool,
    cell: (u32, u32),
}

// SAFETY: the ghostty encoder handles are plain heap objects with no thread affinity; they are
// only ever used behind the `Mutex<Encoders>` on `Vt`.
unsafe impl Send for Encoders {}

impl Encoders {
    pub(crate) fn new() -> Result<Self, ghostty_vt::Error> {
        Ok(Encoders {
            key: KeyEncoder::new()?,
            mouse: MouseEncoder::new()?,
            tracking: false,
            any_motion: false,
            focus: false,
            sgr_pixels: false,
            cell: (1, 1),
        })
    }

    /// Reads the live modes and geometry from `t`. `cell_px` of zero means unknown (1x1 cells).
    pub(crate) fn configure(&mut self, t: &Terminal, cell_px: (u32, u32)) {
        self.key.set_from_terminal(t);
        self.key.set_macos_option_as_alt(true);
        self.mouse.set_from_terminal(t);
        self.tracking = t.mouse_tracking_enabled().unwrap_or(false);
        self.any_motion = t.mode_get(MODE_MOUSE_ANY_MOTION).unwrap_or(false);
        self.focus = t.mode_get(ghostty_vt::MODE_FOCUS_EVENT).unwrap_or(false);
        self.sgr_pixels = t
            .mode_get(ghostty_vt::MODE_MOUSE_SGR_PIXELS)
            .unwrap_or(false);
        self.cell = (cell_px.0.max(1), cell_px.1.max(1));
        if self.sgr_pixels {
            self.mouse.set_format(ghostty_vt::MOUSE_FORMAT_SGR_PIXELS);
        }
        if let (Ok(c), Ok(r)) = (t.cols(), t.rows()) {
            let (cw, ch) = self.cell;
            self.mouse.set_size(c as u32 * cw, r as u32 * ch, cw, ch);
        }
    }
}

impl Vt {
    pub fn encode_key(&self, k: &KeyInput) -> Vec<u8> {
        let Some(ev) = key_event(k) else {
            return Vec::new();
        };
        lock(&self.encoders).key.encode(&ev).unwrap_or_default()
    }

    /// `None` when the terminal has no mouse tracking, or the event is not reportable.
    pub fn encode_mouse(&self, m: &MouseInput) -> Option<Vec<u8>> {
        let mut enc = lock(&self.encoders);
        if !enc.tracking || (m.kind == MouseKind::Move && !enc.any_motion) {
            return None;
        }
        let mut ev = MouseEvent::new().ok()?;
        ev.set_action(match m.kind {
            MouseKind::Release => ghostty_vt::MOUSE_ACTION_RELEASE,
            MouseKind::Move | MouseKind::Drag => ghostty_vt::MOUSE_ACTION_MOTION,
            MouseKind::Press | MouseKind::Scroll => ghostty_vt::MOUSE_ACTION_PRESS,
        });
        match (m.kind, m.button) {
            (MouseKind::Move, _) | (MouseKind::Drag, None) => ev.clear_button(),
            (_, None) => return None,
            (_, Some(b)) => ev.set_button(match b {
                MouseButton::Left => ghostty_vt::MOUSE_BUTTON_LEFT,
                MouseButton::Middle => ghostty_vt::MOUSE_BUTTON_MIDDLE,
                MouseButton::Right => ghostty_vt::MOUSE_BUTTON_RIGHT,
                MouseButton::WheelUp => ghostty_vt::MOUSE_BUTTON_WHEEL_UP,
                MouseButton::WheelDown => ghostty_vt::MOUSE_BUTTON_WHEEL_DOWN,
                MouseButton::WheelLeft => ghostty_vt::MOUSE_BUTTON_WHEEL_LEFT,
                MouseButton::WheelRight => ghostty_vt::MOUSE_BUTTON_WHEEL_RIGHT,
            }),
        }
        ev.set_mods(m.mods.raw());
        let (cw, ch) = enc.cell;
        let (px, py) = m.px.unwrap_or((
            (m.x as f32 + 0.5) * cw as f32,
            (m.y as f32 + 0.5) * ch as f32,
        ));
        ev.set_position(px, py);
        enc.mouse.encode(&ev).ok().filter(|b| !b.is_empty())
    }

    pub fn encode_focus(&self, focused: bool) -> Vec<u8> {
        if !lock(&self.encoders).focus {
            return Vec::new();
        }
        let e = if focused {
            FocusEvent::Gained
        } else {
            FocusEvent::Lost
        };
        ghostty_vt::encode_focus(e).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn vt() -> Arc<Vt> {
        Vt::new(20, 5, 100).expect("vt")
    }

    fn key(key: Key, mods: Mods) -> KeyInput {
        KeyInput {
            key,
            mods,
            event: KeyAction::Press,
            text: None,
        }
    }

    fn ch(s: &str) -> KeyInput {
        key(Key::Char(s.into()), Mods::default())
    }

    fn named(n: NamedKey) -> KeyInput {
        key(Key::Named(n), Mods::default())
    }

    fn mouse(kind: MouseKind, button: Option<MouseButton>, x: u16, y: u16) -> MouseInput {
        MouseInput {
            kind,
            button,
            x,
            y,
            mods: Mods::default(),
            px: None,
        }
    }

    #[test]
    fn plain_char() {
        assert_eq!(vt().encode_key(&ch("a")), b"a");
        let mut k = ch("a");
        k.text = Some("a".into());
        assert_eq!(vt().encode_key(&k), b"a");
    }

    #[test]
    fn enter_is_cr() {
        assert_eq!(vt().encode_key(&named(NamedKey::Enter)), b"\r");
    }

    #[test]
    fn cursor_keys_mode_changes_up() {
        let vt = vt();
        assert_eq!(vt.encode_key(&named(NamedKey::Up)), b"\x1b[A");
        vt.write(b"\x1b[?1h");
        assert_eq!(vt.encode_key(&named(NamedKey::Up)), b"\x1bOA");
    }

    #[test]
    fn ctrl_c_is_etx() {
        let mods = Mods {
            ctrl: true,
            ..Mods::default()
        };
        assert_eq!(vt().encode_key(&key(Key::Char("c".into()), mods)), b"\x03");
    }

    #[test]
    fn kitty_flags_change_encoding() {
        let vt = vt();
        assert_eq!(vt.encode_key(&named(NamedKey::Escape)), b"\x1b");
        vt.write(b"\x1b[>1u");
        assert_eq!(vt.encode_key(&named(NamedKey::Escape)), b"\x1b[27u");
    }

    #[test]
    fn uppercase_and_alt_and_names() {
        let vt = vt();
        assert_eq!(vt.encode_key(&ch("A")), b"A");
        let alt = Mods {
            alt: true,
            ..Mods::default()
        };
        assert_eq!(vt.encode_key(&key(Key::Char("x".into()), alt)), b"\x1bx");
        assert_eq!(vt.encode_key(&named(NamedKey::F(1))), b"\x1bOP");
        assert_eq!(NamedKey::from_name("f12"), Some(NamedKey::F(12)));
        assert_eq!(NamedKey::from_name("f25"), None);
        assert_eq!(NamedKey::from_name("kp_0"), Some(NamedKey::Kp(0)));
        assert_eq!(NamedKey::from_name("page_up"), Some(NamedKey::PageUp));
        assert_eq!(NamedKey::from_name("bogus"), None);
    }

    #[test]
    fn mouse_none_without_tracking() {
        let m = mouse(MouseKind::Press, Some(MouseButton::Left), 4, 2);
        assert_eq!(vt().encode_mouse(&m), None);
    }

    #[test]
    fn mouse_sgr_press() {
        let vt = vt();
        vt.write(b"\x1b[?1000h\x1b[?1006h");
        let press = mouse(MouseKind::Press, Some(MouseButton::Left), 4, 2);
        assert_eq!(vt.encode_mouse(&press), Some(b"\x1b[<0;5;3M".to_vec()));
        let rel = mouse(MouseKind::Release, Some(MouseButton::Left), 4, 2);
        assert_eq!(vt.encode_mouse(&rel), Some(b"\x1b[<0;5;3m".to_vec()));
        let wheel = mouse(MouseKind::Scroll, Some(MouseButton::WheelUp), 0, 0);
        assert_eq!(vt.encode_mouse(&wheel), Some(b"\x1b[<64;1;1M".to_vec()));
        // Plain motion needs any-motion tracking.
        assert_eq!(vt.encode_mouse(&mouse(MouseKind::Move, None, 1, 1)), None);
        vt.write(b"\x1b[?1003h");
        assert!(vt
            .encode_mouse(&mouse(MouseKind::Move, None, 1, 1))
            .is_some());
    }

    #[test]
    fn mouse_cell_centre_with_cell_px_and_resize() {
        let vt = vt();
        vt.resize(20, 5, Some((8, 16))).expect("resize");
        vt.write(b"\x1b[?1000h\x1b[?1006h");
        let press = mouse(MouseKind::Press, Some(MouseButton::Left), 4, 2);
        assert_eq!(vt.encode_mouse(&press), Some(b"\x1b[<0;5;3M".to_vec()));
        // Explicit pixels land in the cell they fall in.
        let mut p = press;
        p.px = Some((33.0, 40.0));
        assert_eq!(vt.encode_mouse(&p), Some(b"\x1b[<0;5;3M".to_vec()));
    }

    #[test]
    fn focus_empty_until_mode() {
        let vt = vt();
        assert_eq!(vt.encode_focus(true), b"");
        vt.write(b"\x1b[?1004h");
        assert_eq!(vt.encode_focus(true), b"\x1b[I");
        assert_eq!(vt.encode_focus(false), b"\x1b[O");
    }
}
