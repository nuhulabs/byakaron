using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Byakaron.Settings;

/// <summary>
/// The shared keyboard settings and the personal dictionary, read and written
/// through <see cref="ByakaronSettings"/> (a composer on the keyboard's data directory).
/// </summary>
public sealed partial class SettingsPanel : UserControl
{
    private readonly ByakaronSettings? _store;
    private readonly KeyboardSettings _settings;
    private bool _loading = true;

    public SettingsPanel()
    {
        InitializeComponent();
        _store = ByakaronSettings.Open();
        _settings = _store?.Load() ?? new KeyboardSettings();
        Unloaded += (_, _) => _store?.Dispose();

        LoadControls();
        RefreshUserWords();
        if (_store is null)
        {
            UnavailableText.Visibility = Visibility.Visible;
            foreach (var control in new Control[]
            {
                SuggestionsToggle, SpellingToggle, LearnToggle, DigitsToggle, NewlineToggle,
                OrientationCombo, PerPageSlider, NewWordBox, AddWordButton,
            })
            {
                control.IsEnabled = false;
            }
        }
        _loading = false;
    }

    private void LoadControls()
    {
        SuggestionsToggle.IsOn = _settings.Suggestions;
        SpellingToggle.IsOn = _settings.SpellingCorrections;
        LearnToggle.IsOn = _settings.LearnChoices;
        DigitsToggle.IsOn = _settings.BanglaDigits;
        NewlineToggle.IsOn = _settings.NewlineOnEnter;
        OrientationCombo.SelectedIndex = _settings.Vertical ? 1 : 0;
        PerPageSlider.Value = _settings.CandidatesPerPage;
        PerPageValueText.Text = $"{_settings.CandidatesPerPage} suggestions";
    }

    private void Save()
    {
        _store?.Save(_settings);
    }

    private void Toggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Suggestions = SuggestionsToggle.IsOn;
        _settings.SpellingCorrections = SpellingToggle.IsOn;
        _settings.LearnChoices = LearnToggle.IsOn;
        _settings.BanglaDigits = DigitsToggle.IsOn;
        _settings.NewlineOnEnter = NewlineToggle.IsOn;
        Save();
    }

    private void OrientationCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (OrientationCombo.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            _settings.Vertical = tag == "vertical";
            Save();
        }
    }

    private void PerPageSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_loading || PerPageValueText is null) return;
        var n = (int)PerPageSlider.Value;
        _settings.CandidatesPerPage = n;
        PerPageValueText.Text = $"{n} suggestions";
        Save();
    }

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
