using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Byakaron.Settings;

/// <summary>
/// The shared keyboard settings and the personal dictionary, read and written
/// through <see cref="ByakaronSettings"/> (a composer on the keyboard's data directory).
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

        BuildSettings();
        RefreshUserWords();
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

    // One group per manifest section: its title, its fields, then its hint.
    private void BuildSettings()
    {
        foreach (var section in ByakaronSettings.Manifest())
        {
            var group = new StackPanel { Spacing = 8 };
            group.Children.Add(new TextBlock { Text = section.Title, Style = ResourceStyle("SectionTitleStyle") });
            foreach (var field in section.Fields)
            {
                AddField(group, field);
            }
            if (!string.IsNullOrEmpty(section.Hint))
            {
                group.Children.Add(Hint(section.Hint));
            }
            ManifestPanel.Children.Add(group);
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
                group.Children.Add(new TextBlock { Text = field.Title, Style = ResourceStyle("FieldTitleStyle") });
                var combo = new ComboBox { MinWidth = 200 };
                foreach (var option in field.Options)
                {
                    combo.Items.Add(new ComboBoxItem { Content = option });
                }
                combo.SelectedIndex = value >= 0 && value < field.Options.Count ? value : -1;
                combo.SelectionChanged += (_, _) =>
                {
                    if (combo.SelectedIndex >= 0) Save(field.Key, combo.SelectedIndex);
                };
                group.Children.Add(combo);
                _settingControls.Add(combo);
                break;
            }
            case SettingControl.Number:
            {
                group.Children.Add(new TextBlock { Text = field.Title, Style = ResourceStyle("FieldTitleStyle") });
                var slider = new Slider
                {
                    Minimum = field.Min,
                    Maximum = field.Max,
                    StepFrequency = 1,
                    TickFrequency = 1,
                    Value = value,
                };
                var shown = new TextBlock { Text = value.ToString(), Style = ResourceStyle("HintStyle") };
                slider.ValueChanged += (_, e) =>
                {
                    var n = (int)e.NewValue;
                    shown.Text = n.ToString();
                    Save(field.Key, n);
                };
                group.Children.Add(slider);
                group.Children.Add(shown);
                _settingControls.Add(slider);
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
