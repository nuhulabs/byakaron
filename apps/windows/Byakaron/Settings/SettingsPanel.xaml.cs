using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Byakaron.Keyboard;

namespace Byakaron.Settings;

/// <summary>
/// The Settings tabs, as the macOS app has them: Setup (install and switch to
/// the keyboard), Typing and Suggestions (the shared settings, from the core's
/// manifest), the personal dictionary, and the Avro layout. Settings are read
/// and written through <see cref="ByakaronSettings"/> (a composer on the
/// keyboard's data directory); the keyboard picks them up at its next word.
/// </summary>
public sealed partial class SettingsPanel : UserControl
{
    private readonly ByakaronSettings? _store;
    private readonly List<Control> _settingControls = new();
    private bool _loading = true;

    public SettingsPanel()
    {
        InitializeComponent();
        _store = ByakaronSettings.Open();
        Unloaded += (_, _) => _store?.Dispose();

        BuildSetup();
        BuildSettings();
        BuildLayout();
        RefreshUserWords();
        Updates.Updater.Shared.StateChanged += RefreshUpdateStatus;
        Unloaded += (_, _) => Updates.Updater.Shared.StateChanged -= RefreshUpdateStatus;
        RefreshUpdateStatus();
        if (_store is null)
        {
            UnavailableText.Visibility = Visibility.Visible;
            _settingControls.Add(NewWordBox);
            _settingControls.Add(AddWordButton);
            foreach (var control in _settingControls)
            {
                control.IsEnabled = false;
            }
        }
        _loading = false;
    }

    private void Tabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        // Raised while the XAML loads, before the pages exist.
        if (SetupPage is null || LayoutPage is null || UpdatesPage is null) return;
        var tag = sender.SelectedItem?.Tag as string ?? "setup";
        SetupPage.Visibility = tag == "setup" ? Visibility.Visible : Visibility.Collapsed;
        TypingPage.Visibility = tag == "typing" ? Visibility.Visible : Visibility.Collapsed;
        CandidatesPage.Visibility = tag == "candidates" ? Visibility.Visible : Visibility.Collapsed;
        DictionaryPage.Visibility = tag == "dictionary" ? Visibility.Visible : Visibility.Collapsed;
        LayoutPage.Visibility = tag == "layout" ? Visibility.Visible : Visibility.Collapsed;
        UpdatesPage.Visibility = tag == "updates" ? Visibility.Visible : Visibility.Collapsed;
        if (tag == "setup") RefreshKeyboardStatus();
    }

    // ── Setup ──

    private static readonly string[] SetupStepText =
    {
        "Install the keyboard (below). Byakaron adds itself under Bangla (Bangladesh).",
        "Open Settings → Time & language → Language & region to check that \"Byakaron Phonetic\" is listed.",
        "Press Win+Space, or use the taskbar's input indicator, to switch to Byakaron.",
    };

    private static readonly (string Key, string What)[] TypingTipText =
    {
        ("Type phonetically", "ami → আমি,  bangla → বাংলা"),
        ("Space", "commits the highlighted suggestion"),
        ("1–9", "picks that suggestion"),
        ("Arrow keys", "move through the suggestions"),
        ("Backspace", "deletes the last letter"),
        ("Escape", "cancels the word"),
    };

    private void BuildSetup()
    {
        for (var i = 0; i < SetupStepText.Length; i++)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var badge = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(11),
                Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
                VerticalAlignment = VerticalAlignment.Top,
                Child = new TextBlock
                {
                    Text = (i + 1).ToString(),
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"],
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            var text = new TextBlock { Text = SetupStepText[i], TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, 1);
            row.Children.Add(badge);
            row.Children.Add(text);
            SetupSteps.Children.Add(row);
        }

        foreach (var (key, what) in TypingTipText)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var k = new TextBlock { Text = key, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
            var w = new TextBlock { Text = what, Style = ResourceStyle("HintStyle"), FontSize = 13 };
            Grid.SetColumn(w, 1);
            row.Children.Add(k);
            row.Children.Add(w);
            TypingTips.Children.Add(row);
        }

        RefreshKeyboardStatus();
    }

    private void RefreshKeyboardStatus()
    {
        var installed = KeyboardInstaller.IsTipPresentOnDisk();
        KeyboardStatusBar.Severity = installed ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        KeyboardStatusBar.Title = installed ? "Keyboard installed" : "Keyboard not installed";
        KeyboardStatusBar.Message = installed
            ? "Switch to Byakaron Phonetic with Win+Space."
            : "Install it to type Bangla in every app.";
        InstallButton.Content = installed ? "Reinstall keyboard" : "Install keyboard";
    }

    private async void InstallButton_Click(object sender, RoutedEventArgs e)
    {
        InstallButton.IsEnabled = false;
        try
        {
            var result = await KeyboardInstaller.EnsureInstalledAsync();
            RefreshKeyboardStatus();
            if (!result.Success)
            {
                KeyboardStatusBar.Severity = InfoBarSeverity.Error;
                KeyboardStatusBar.Title = "Install failed";
                KeyboardStatusBar.Message = result.Message;
            }
        }
        finally
        {
            InstallButton.IsEnabled = true;
        }
    }

    private async void LanguageSettings_Click(object sender, RoutedEventArgs e)
    {
        await KeyboardInstaller.OpenLanguageSettingsAsync();
    }

    // ── Typing and Suggestions ──

    // A manifest section per tab: its fields, then its hint.
    private void BuildSettings()
    {
        foreach (var section in ByakaronSettings.Manifest())
        {
            var page = section.Id switch
            {
                "typing" => TypingPage,
                "candidates" => CandidatesPage,
                "updates" => UpdatesSettings,
                _ => null,
            };
            if (page is null) continue;
            page.Children.Add(new TextBlock { Text = section.Title, Style = ResourceStyle("SectionTitleStyle") });
            foreach (var field in section.Fields)
            {
                var group = new StackPanel { Spacing = 4 };
                AddField(group, field);
                page.Children.Add(group);
            }
            if (!string.IsNullOrEmpty(section.Hint))
            {
                page.Children.Add(Hint(section.Hint));
            }
        }
    }

    // ── Updates ──

    private void RefreshUpdateStatus()
    {
        var updater = Updates.Updater.Shared;
        var busy = updater.State is Updates.UpdateState.Checking or Updates.UpdateState.Downloading;
        UpdateProgress.IsActive = busy;
        UpdateButton.IsEnabled = !busy;
        UpdateButton.Content = updater.State == Updates.UpdateState.Ready ? "Restart to update" : "Check now";
        UpdateStatusText.Text = $"Byakaron {updater.CurrentVersion}. {updater.StatusText}";
    }

    private async void UpdateButton_Click(object sender, RoutedEventArgs e)
    {
        var updater = Updates.Updater.Shared;
        if (updater.State == Updates.UpdateState.Ready)
        {
            updater.RestartAndInstall();
            return;
        }
        await updater.CheckAsync();
    }

    // ── Layout ──

    private void BuildLayout()
    {
        foreach (var section in LayoutReference.Sections)
        {
            LayoutPage.Children.Add(new TextBlock { Text = section.Title, Style = ResourceStyle("SectionTitleStyle") });
            var grid = new VariableSizedWrapGrid
            {
                Orientation = Orientation.Horizontal,
                ItemWidth = 148,
                ItemHeight = 30,
            };
            foreach (var (bangla, keys) in section.Entries)
            {
                var cell = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                cell.Children.Add(new TextBlock { Text = bangla, FontFamily = new FontFamily("Nirmala UI"), FontSize = 16, MinWidth = 40, VerticalAlignment = VerticalAlignment.Center });
                cell.Children.Add(new Border
                {
                    Padding = new Thickness(6, 1, 6, 1),
                    CornerRadius = new CornerRadius(4),
                    Background = (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"],
                    BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"],
                    BorderThickness = new Thickness(1),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new TextBlock { Text = keys, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 },
                });
                grid.Children.Add(cell);
            }
            LayoutPage.Children.Add(grid);
        }
    }

    private void AddField(StackPanel group, SettingsField field)
    {
        var value = _store?.Get(field.Key) ?? field.Min;
        switch (field.Control)
        {
            case SettingControl.Toggle:
            {
                var toggle = new ToggleSwitch { Header = field.Title, IsOn = value != 0 };
                toggle.Toggled += (_, _) => Save(field.Key, toggle.IsOn ? 1 : 0);
                group.Children.Add(toggle);
                _settingControls.Add(toggle);
                break;
            }
            case SettingControl.Choice:
            {
                // A row of options, like the macOS app's segmented control.
                var choice = new RadioButtons { Header = field.Title, MaxColumns = Math.Max(1, field.Options.Count) };
                foreach (var option in field.Options)
                {
                    choice.Items.Add(option);
                }
                choice.SelectedIndex = value >= 0 && value < field.Options.Count ? value : -1;
                choice.SelectionChanged += (_, _) =>
                {
                    if (choice.SelectedIndex >= 0) Save(field.Key, choice.SelectedIndex);
                };
                group.Children.Add(choice);
                _settingControls.Add(choice);
                break;
            }
            case SettingControl.Number:
            {
                // A stepper, like the macOS app's.
                var number = new NumberBox
                {
                    Header = field.Title,
                    Minimum = field.Min,
                    Maximum = field.Max,
                    SmallChange = 1,
                    LargeChange = 1,
                    Value = value,
                    SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    MinWidth = 140,
                };
                number.ValueChanged += (_, e) =>
                {
                    if (double.IsNaN(e.NewValue)) return;
                    var n = (int)Math.Clamp(Math.Round(e.NewValue), field.Min, field.Max);
                    Save(field.Key, n);
                };
                group.Children.Add(number);
                _settingControls.Add(number);
                break;
            }
            default:
                return; // a control this app does not know yet
        }

        if (!string.IsNullOrEmpty(field.Hint))
        {
            group.Children.Add(Hint(field.Hint));
        }
    }

    private void Save(string key, int value)
    {
        if (_loading) return;
        _store?.Set(key, value);
        // What was found for the old channel may not be right for the new one.
        if (key == "update_channel") Updates.Updater.Shared.ChannelChanged();
    }

    private TextBlock Hint(string text) => new() { Text = text, Style = ResourceStyle("HintStyle") };

    private Microsoft.UI.Xaml.Style ResourceStyle(string key) => (Microsoft.UI.Xaml.Style)Resources[key];

    private void AddWord_Click(object sender, RoutedEventArgs e)
    {
        if (_store is null) return;
        var word = (NewWordBox.Text ?? string.Empty).Trim();
        if (word.Length == 0) return;

        var result = _store.AddUserWord(word);
        if (result == 1)
        {
            NewWordBox.Text = string.Empty;
            ShowWordStatus(null);
            RefreshUserWords();
        }
        else
        {
            ShowWordStatus(result == 0 ? "Already in your dictionary." : "Enter a single Bangla word.");
        }
    }

    private void NewWordBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        e.Handled = true;
        AddWord_Click(sender, e);
    }

    private void RemoveWord_Click(object sender, RoutedEventArgs e)
    {
        if (_store is null || sender is not Button { Tag: string word }) return;
        _store.RemoveUserWord(word);
        ShowWordStatus(null);
        RefreshUserWords();
    }

    private void ShowWordStatus(string? message)
    {
        WordStatusText.Text = message ?? string.Empty;
        WordStatusText.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RefreshUserWords()
    {
        UserWordsPanel.Children.Clear();
        var words = _store?.UserWords() ?? new System.Collections.Generic.List<string>();
        UserWordsEmptyText.Visibility = words.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        foreach (var word in words)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var text = new TextBlock
            {
                Text = word,
                FontSize = 15,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var remove = new Button
            {
                Content = new SymbolIcon(Symbol.Delete),
                Tag = word,
                Padding = new Thickness(6),
            };
            ToolTipService.SetToolTip(remove, "Remove");
            remove.Click += RemoveWord_Click;
            Grid.SetColumn(remove, 1);

            row.Children.Add(text);
            row.Children.Add(remove);
            UserWordsPanel.Children.Add(row);
        }
    }
}
