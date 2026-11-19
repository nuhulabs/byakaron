using System;
using System.Runtime.InteropServices;
using System.Text;
using Byakaron.Interop;
using Byakaron.Typing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Win32;
using Windows.Foundation;
using Windows.System;

namespace Byakaron;

/// <summary>
/// "Avro typing" in the editor: key events go to the keyboard's composer (see
/// <see cref="AvroComposer"/>) the way the installed keyboard sends them, so
/// its typing, suggestions and settings can be tried here. The macOS app's
/// ComposingTextView does the same. A TextBox has no marked text, so the word
/// being typed is ordinary text whose range is remembered here: each redraw
/// replaces it with the composer's highlighted candidate, and a commit
/// replaces it with the committed text.
/// </summary>
public sealed partial class MainWindow
{
    private const string PrefsKey = @"Software\Byakaron";
    private const string PlainPlaceholder = "এখানে বাংলা লিখুন বা পেস্ট করুন…";
    private const string AvroPlaceholder = "ইংরেজিতে লিখুন: ami banglay gan gai…";

    private AvroComposer? _avro;
    private bool _avroTyping;
    /// <summary>Where the word being typed starts in the editor's text, -1 when none.</summary>
    private int _wordStart = -1;
    private int _wordLength;
    /// <summary>Set while we change the editor's text or caret ourselves.</summary>
    private bool _editingWord;

    private void InitAvroTyping()
    {
        _avroTyping = LoadAvroTypingPref();
        AvroTypingToggle.IsChecked = _avroTyping;
        EditorTextBox.PlaceholderText = _avroTyping ? AvroPlaceholder : PlainPlaceholder;
        Closed += (_, _) =>
        {
            FlushWord();
            _avro?.Dispose();
            _avro = null;
        };
    }

    private AvroComposer? AvroEngine()
    {
        _avro ??= AvroComposer.Open(() => _dispatcher.TryEnqueue(() =>
        {
            // Spelling corrections arrived on the composer's worker thread.
            if (_avro is null) return;
            _avro.Refresh();
            if (_wordStart >= 0) RedrawWord();
        }));
        return _avro;
    }

    private void AvroTypingToggle_Click(object sender, RoutedEventArgs e)
    {
        var on = AvroTypingToggle.IsChecked == true;
        if (on && AvroEngine() is null)
        {
            AvroTypingToggle.IsChecked = false;
            SubtitleText.Text = "Phonetic typing is unavailable. Reinstall Byakaron to fix this.";
            return;
        }
        if (!on) FlushWord();
        _avroTyping = on;
        SaveAvroTypingPref(on);
        EditorTextBox.PlaceholderText = on ? AvroPlaceholder : PlainPlaceholder;
        EditorTextBox.Focus(FocusState.Programmatic);
    }

    // ── Keys ──

    private void EditorTextBox_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_avroTyping || AvroEngine() is not { } composer) return;
        if (!MapKey(e, out var kind, out var ch, out var mods)) return;
        // Unused keys still reach the editor, after any commit (Enter, Backspace at rest).
        e.Handled = Apply(composer.Key(kind, ch, mods));
    }

    /// <summary>Insert the result's commit, redraw, and report whether the key was used.</summary>
    private bool Apply(ComposerResult result)
    {
        if (result.Commit.Length > 0) CommitText(result.Commit);
        RedrawWord();
        return result.Handled;
    }

    /// <summary>The composer key for a key event; false for keys it never sees (modifiers, an IME's).</summary>
    private static bool MapKey(KeyRoutedEventArgs e, out int kind, out uint ch, out uint mods)
    {
        kind = ByakaronNative.KeyOther;
        ch = 0;
        mods = 0;

        var state = new byte[256];
        GetKeyboardState(state);
        bool Down(VirtualKey k) => (state[(int)k] & 0x80) != 0;
        if (Down(VirtualKey.Shift)) mods |= ByakaronNative.ModShift;
        if (Down(VirtualKey.Control)) mods |= ByakaronNative.ModCtrl;
        if (Down(VirtualKey.Menu)) mods |= ByakaronNative.ModAlt;
        if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) mods |= ByakaronNative.ModMeta;

        switch (e.Key)
        {
            case VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift
                or VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl
                or VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
                or VirtualKey.LeftWindows or VirtualKey.RightWindows or VirtualKey.CapitalLock:
                return false;
            case (VirtualKey)229: // VK_PROCESSKEY: another IME (the Byakaron keyboard, say) has it
                return false;
            case VirtualKey.Space: kind = ByakaronNative.KeySpace; return true;
            case VirtualKey.Enter: kind = ByakaronNative.KeyEnter; return true;
            case VirtualKey.Tab: kind = ByakaronNative.KeyTab; return true;
            case VirtualKey.Back: kind = ByakaronNative.KeyBackspace; return true;
            case VirtualKey.Escape: kind = ByakaronNative.KeyEscape; return true;
            case VirtualKey.Up: kind = ByakaronNative.KeyUp; return true;
            case VirtualKey.Down: kind = ByakaronNative.KeyDown; return true;
            case VirtualKey.Left: kind = ByakaronNative.KeyLeft; return true;
            case VirtualKey.Right: kind = ByakaronNative.KeyRight; return true;
            case VirtualKey.PageUp: kind = ByakaronNative.KeyPageUp; return true;
            case VirtualKey.PageDown: kind = ByakaronNative.KeyPageDown; return true;
        }

        // Ctrl/Alt change what ToUnicode types; the composer passes shortcuts on
        // whatever the character, so give it the plain letter or digit.
        var vk = (uint)e.Key;
        if ((mods & (ByakaronNative.ModCtrl | ByakaronNative.ModAlt | ByakaronNative.ModMeta)) != 0)
        {
            if (vk is >= 0x41 and <= 0x5A) { kind = ByakaronNative.KeyChar; ch = vk + 32; } // A-Z
            else if (vk is >= 0x30 and <= 0x39) { kind = ByakaronNative.KeyChar; ch = vk; } // 0-9
            return true;
        }

        // The character this key types in the current layout, without touching
        // dead-key state (flag 4).
        var buffer = new StringBuilder(8);
        var n = ToUnicode(vk, e.KeyStatus.ScanCode, state, buffer, buffer.Capacity, 4);
        if (n == 1 && buffer[0] is >= '!' and <= '~')
        {
            kind = ByakaronNative.KeyChar;
            ch = buffer[0];
        }
        return true;
    }

    [DllImport("user32.dll")]
    private static extern bool GetKeyboardState(byte[] state);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ToUnicode(uint vk, uint scan, byte[] state, StringBuilder buffer, int size, uint flags);

    // ── The word in the editor ──

    /// <summary>Replace the word being typed (or the selection) with <paramref name="text"/>, caret after it.</summary>
    private void CommitText(string text)
    {
        if (_wordStart >= 0)
        {
            ReplaceRange(_wordStart, _wordLength, text);
            _wordStart = -1;
            _wordLength = 0;
            return;
        }
        ReplaceRange(EditorTextBox.SelectionStart, EditorTextBox.SelectionLength, text);
    }

    /// <summary>Draw the composer's state: the highlighted candidate in place of the word, and the pills.</summary>
    private void RedrawWord()
    {
        if (_avro is null) return;
        var st = _avro.State();
        if (st.Composing)
        {
            if (_wordStart < 0)
            {
                // The word starts at the caret, replacing what is selected.
                _wordStart = EditorTextBox.SelectionStart;
                _wordLength = EditorTextBox.SelectionLength;
            }
            ReplaceRange(_wordStart, _wordLength, st.Preedit);
            _wordLength = st.Preedit.Length;
        }
        else if (_wordStart >= 0)
        {
            // The word was dropped (Esc, or Backspace to empty).
            ReplaceRange(_wordStart, _wordLength, string.Empty);
            _wordStart = -1;
            _wordLength = 0;
        }
        DrawPills(st);
    }

    private void ReplaceRange(int start, int length, string text)
    {
        _editingWord = true;
        try
        {
            var total = EditorTextBox.Text.Length;
            start = Math.Clamp(start, 0, total);
            length = Math.Clamp(length, 0, total - start);
            EditorTextBox.Select(start, length);
            EditorTextBox.SelectedText = text;
            EditorTextBox.Select(start + text.Length, 0);
        }
        finally
        {
            _editingWord = false;
        }
    }

    /// <summary>Commit the word being typed where it stands.</summary>
    private void FlushWord()
    {
        if (_avro is null) return;
        if (_wordStart >= 0)
        {
            var text = _avro.Flush();
            CommitText(text.Length > 0 ? text : EditorTextBox.Text.Substring(_wordStart, _wordLength));
        }
        else
        {
            _avro.Reset();
        }
        HidePills();
    }

    /// <summary>Forget the word being typed: the text it was in was replaced.</summary>
    private void DropWord()
    {
        _avro?.Reset();
        _wordStart = -1;
        _wordLength = 0;
        HidePills();
    }

    private void EditorTextBox_SelectionChanged(object sender, RoutedEventArgs e)
    {
        if (_editingWord || _wordStart < 0 || _avro is null) return;
        var caret = _wordStart + _wordLength;
        if (EditorTextBox.SelectionStart == caret && EditorTextBox.SelectionLength == 0) return;

        // A click or a menu moved the caret off the word: commit it where it
        // stands and keep the caret where it went.
        var selStart = EditorTextBox.SelectionStart;
        var selLength = EditorTextBox.SelectionLength;
        var start = _wordStart;
        var oldLength = _wordLength;
        var text = _avro.Flush();
        if (text.Length == 0) text = EditorTextBox.Text.Substring(start, oldLength);
        CommitText(text);
        if (selStart >= start + oldLength) selStart += text.Length - oldLength;
        _editingWord = true;
        EditorTextBox.Select(Math.Min(selStart, EditorTextBox.Text.Length), selLength);
        _editingWord = false;
        HidePills();
    }

    private void EditorTextBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_wordStart >= 0) FlushWord();
    }

    // ── The pills ──

    private void HidePills() => CandidatePopup.IsOpen = false;

    /// <summary>The keyboard's pill panel in XAML: numbered pills, the highlighted one filled, chevrons to page.</summary>
    private void DrawPills(ComposerSnapshot st)
    {
        if (!st.PanelVisible || st.Candidates.Count == 0 || _wordStart < 0)
        {
            HidePills();
            return;
        }

        var items = new StackPanel { Orientation = st.Vertical ? Orientation.Vertical : Orientation.Horizontal };
        for (var i = 0; i < st.Candidates.Count; i++)
        {
            items.Children.Add(Pill(i, st.Candidates[i], i == st.Highlight));
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        row.Children.Add(items);
        if (st.PageCount > 1)
        {
            var pages = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            pages.Children.Add(Chevron("", st.Page > 0, ByakaronNative.KeyPageUp));
            pages.Children.Add(Chevron("", st.Page + 1 < st.PageCount, ByakaronNative.KeyPageDown));
            row.Children.Add(pages);
        }

        CandidatePill.Child = row;
        CandidatePill.Background = ThemeBrush("AppPillBrush");
        CandidatePill.BorderBrush = ThemeBrush("AppPillBorderBrush");
        CandidatePill.CornerRadius = new CornerRadius(st.Vertical ? 12 : 16);

        // Below the word, its first letter under the first pill's text; above
        // it when the window has no room below.
        CandidatePill.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = CandidatePill.DesiredSize;
        try
        {
            var rect = EditorTextBox.GetRectFromCharacterIndex(_wordStart, false);
            var at = EditorTextBox.TransformToVisual(RootGrid).TransformPoint(new Point(rect.Left, rect.Bottom));
            var y = at.Y + 4;
            if (y + size.Height > RootGrid.ActualHeight) y = at.Y - rect.Height - 4 - size.Height;
            CandidatePopup.HorizontalOffset = Math.Max(0, at.X - 12);
            CandidatePopup.VerticalOffset = Math.Max(0, y);
        }
        catch (ArgumentException)
        {
            // No layout for that index yet: keep the last place.
        }
        CandidatePopup.IsOpen = true;
    }

    private Border Pill(int index, string word, bool selected)
    {
        var text = selected ? ThemeBrush("AppPillSelectedTextBrush") : ThemeBrush("AppPillTextBrush");
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        content.Children.Add(new TextBlock
        {
            Text = (index + 1).ToString(),
            FontSize = 11,
            Opacity = selected ? 0.9 : 0.6,
            Foreground = text,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 3), // a little high, beside the word
        });
        content.Children.Add(new TextBlock
        {
            Text = word,
            FontFamily = new FontFamily("Nirmala UI"),
            FontSize = 16,
            Foreground = text,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var idle = selected ? ThemeBrush("AppPillSelectedBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var pill = new Border
        {
            Child = content,
            Padding = new Thickness(9, 2, 9, 3),
            CornerRadius = new CornerRadius(14),
            Background = idle,
        };
        if (!selected)
        {
            pill.PointerEntered += (_, _) => pill.Background = ThemeBrush("AppPillHoverBrush");
            pill.PointerExited += (_, _) => pill.Background = idle;
        }
        pill.Tapped += (_, e) =>
        {
            e.Handled = true;
            if (_avro is null) return;
            Apply(_avro.Pick(index));
            EditorTextBox.Focus(FocusState.Programmatic);
        };
        return pill;
    }

    private Border Chevron(string glyph, bool enabled, int key)
    {
        var chevron = new Border
        {
            Padding = new Thickness(3, 0, 3, 0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = 9,
                Foreground = ThemeBrush("AppPillTextBrush"),
                Opacity = enabled ? 0.7 : 0.25,
            },
        };
        if (enabled)
        {
            chevron.Tapped += (_, e) =>
            {
                e.Handled = true;
                if (_avro is null) return;
                Apply(_avro.Key(key, 0, 0));
                EditorTextBox.Focus(FocusState.Programmatic);
            };
        }
        return chevron;
    }

    // ── The toggle, remembered ──

    private static bool LoadAvroTypingPref()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PrefsKey);
            return key?.GetValue("AvroTyping") is int v && v != 0;
        }
        catch
        {
            return false;
        }
    }

    private static void SaveAvroTypingPref(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(PrefsKey);
            key.SetValue("AvroTyping", on ? 1 : 0, RegistryValueKind.DWord);
        }
        catch
        {
            // Not remembered; it still works for this run.
        }
    }
}
