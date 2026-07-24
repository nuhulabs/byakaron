using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using Byakaron.Models;
using Byakaron.Spell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Byakaron;

public sealed partial class MainWindow : Window
{
    private readonly ObservableCollection<SpellIssue> _issues = new();
    private readonly SpellChecker _checker = new();
    private readonly DispatcherQueue _dispatcher;
    private bool _sidebarVisible = true;
    private bool _suppressEditorSync;

    private static readonly string SampleText =
        "আমি বাংলায় লিখি। গিয়ে দেখি নদী বয়ে চলে। হয়ে যায় সন্ধ্যা, দিয়ে রাখি বাতি। " +
        "কিছু শব্দ ভুল থাকতে পারে — সকসমসকসম আর সহমস — যা পরীক্ষক ধরবে।";

    public MainWindow()
    {
        InitializeComponent();

        _dispatcher = DispatcherQueue.GetForCurrentThread();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        IssuesList.ItemsSource = _issues;
        _checker.Changed += Checker_Changed;

        _suppressEditorSync = true;
        EditorTextBox.Text = SampleText;
        _checker.Text = SampleText;
        _suppressEditorSync = false;

        SubtitleText.Text = "Loading dictionary…";
        FixAllButton.IsEnabled = false;
        UpdateChrome();

        _ = LoadEngineAsync();
    }

    private async Task LoadEngineAsync()
    {
        await _checker.LoadAsync();
        if (!_checker.IsReady)
        {
            SubtitleText.Text = "Dictionary unavailable";
            UpdateChrome();
        }
    }

    private void Checker_Changed(object? sender, EventArgs e)
    {
        if (!_dispatcher.HasThreadAccess)
        {
            _dispatcher.TryEnqueue(() => SyncFromChecker());
            return;
        }

        SyncFromChecker();
    }

    private void SyncFromChecker()
    {
        if (_suppressEditorSync)
        {
            // Still refresh issues/chrome after apply/ignore.
        }
        else if (!string.Equals(EditorTextBox.Text, _checker.Text, StringComparison.Ordinal))
        {
            _suppressEditorSync = true;
            EditorTextBox.Text = _checker.Text;
            _suppressEditorSync = false;
        }

        var previousId = (IssuesList.SelectedItem as SpellIssue)?.Id;
        _issues.Clear();

        foreach (var miss in _checker.Misspellings)
        {
            _issues.Add(new SpellIssue
            {
                Id = miss.Id,
                Word = miss.Word,
                Offset = miss.Offset,
                Length = miss.Length,
                Suggestions = _checker.Suggestions(miss),
            });
        }

        if (previousId is not null)
        {
            IssuesList.SelectedItem = _issues.FirstOrDefault(i => i.Id == previousId)
                ?? _issues.FirstOrDefault();
        }
        else if (_issues.Count > 0 && IssuesList.SelectedItem is null)
        {
            IssuesList.SelectedIndex = 0;
        }

        UpdateCorrectionBar();
        UpdateChrome();
    }

    private void SidebarToggleButton_Click(object sender, RoutedEventArgs e)
    {
        _sidebarVisible = !_sidebarVisible;
        if (_sidebarVisible)
        {
            SidebarColumn.MinWidth = 220;
            SidebarColumn.MaxWidth = 340;
            SidebarColumn.Width = new GridLength(268);
            SidebarPane.Visibility = Visibility.Visible;
        }
        else
        {
            // MinWidth must drop too — otherwise the column stays ~220px empty.
            SidebarColumn.MinWidth = 0;
            SidebarColumn.MaxWidth = 0;
            SidebarColumn.Width = new GridLength(0);
            SidebarPane.Visibility = Visibility.Collapsed;
        }
    }

    private void EditorTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressEditorSync)
        {
            return;
        }

        _checker.Text = EditorTextBox.Text ?? string.Empty;
        UpdateChrome();
    }

    private void IssuesList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateCorrectionBar();
    }

    private async void KeyboardButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "Byakaron keyboard",
            PrimaryButtonText = "Install keyboard",
            SecondaryButtonText = "Language settings",
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            Content = new TextBlock
            {
                Text =
                    "Installs a system Text Input Processor (TSF) for Bangla.\n\n" +
                    "Shown as \"Byakaron Phonetic\" (not InScript — InScript is a " +
                    "different key layout). After install, switch with Win+Space or " +
                    "the taskbar input indicator, then type Avro phonetic (ami → আমি).\n\n" +
                    (Keyboard.KeyboardInstaller.IsTipPresentOnDisk()
                        ? $"Installed at:\n{Keyboard.KeyboardInstaller.InstallDirectory}"
                        : "Not installed yet."),
                TextWrapping = TextWrapping.Wrap,
            },
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            var install = await Keyboard.KeyboardInstaller.EnsureInstalledAsync();
            var done = new ContentDialog
            {
                XamlRoot = RootGrid.XamlRoot,
                Title = install.Success ? "Keyboard ready" : "Install failed",
                Content = install.Message,
                CloseButtonText = "OK",
            };
            await done.ShowAsync();
            if (install.Success)
            {
                await Keyboard.KeyboardInstaller.OpenLanguageSettingsAsync();
            }
        }
        else if (result == ContentDialogResult.Secondary)
        {
            await Keyboard.KeyboardInstaller.OpenLanguageSettingsAsync();
        }
    }

    private void FixAllButton_Click(object sender, RoutedEventArgs e)
    {
        if (_checker.FixAll() > 0)
        {
            // Checker_Changed syncs editor + issues.
        }
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        var text = _checker.Text;
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    private void ClearButton_Click(object sender, RoutedEventArgs e)
    {
        _checker.Text = string.Empty;
    }

    private void IgnoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (IssuesList.SelectedItem is not SpellIssue selected)
        {
            return;
        }

        var miss = _checker.Misspellings.FirstOrDefault(m => m.Id == selected.Id);
        if (miss is null)
        {
            return;
        }

        _checker.Ignore(miss);
    }

    private void SuggestionButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Content: string replacement })
        {
            return;
        }

        if (IssuesList.SelectedItem is not SpellIssue selected)
        {
            return;
        }

        var miss = _checker.Misspellings.FirstOrDefault(m => m.Id == selected.Id);
        if (miss is null)
        {
            return;
        }

        var nextOffset = miss.Offset + replacement.Length;
        _checker.Apply(replacement, miss);

        var next = _issues.FirstOrDefault(i => i.Offset >= nextOffset) ?? _issues.FirstOrDefault();
        IssuesList.SelectedItem = next;
    }

    private void UpdateCorrectionBar()
    {
        SuggestionsPanel.Children.Clear();

        if (IssuesList.SelectedItem is not SpellIssue issue)
        {
            CorrectionBar.Visibility = Visibility.Collapsed;
            return;
        }

        var miss = _checker.Misspellings.FirstOrDefault(m => m.Id == issue.Id);
        if (miss is not null && issue.Suggestions.Count == 0)
        {
            issue.Suggestions = _checker.Suggestions(miss);
        }

        CorrectionBar.Visibility = Visibility.Visible;
        CorrectionWordText.Text = issue.Word;

        if (issue.Suggestions.Count == 0)
        {
            SuggestionsPanel.Children.Add(new TextBlock
            {
                Text = "No suggestions",
                FontSize = 13,
                Foreground = (Brush)Application.Current.Resources["AppSecondaryTextBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            });
            return;
        }

        foreach (var suggestion in issue.Suggestions)
        {
            var button = new Button
            {
                Content = suggestion,
                Style = (Style)Application.Current.Resources["SuggestionChipStyle"],
            };
            button.Click += SuggestionButton_Click;
            SuggestionsPanel.Children.Add(button);
        }
    }

    private void UpdateChrome()
    {
        var text = _checker.Text;
        var words = CountWords(text);
        var chars = text.Length;
        var issueCount = _issues.Count;

        WordCountText.Text = $"{words} word{(words == 1 ? string.Empty : "s")}";
        CharCountText.Text = $"{chars} character{(chars == 1 ? string.Empty : "s")}";
        IssuesHeaderText.Text = issueCount == 0 ? "Issues" : $"Issues ({issueCount})";

        if (!_checker.IsReady)
        {
            if (SubtitleText.Text is not ("Loading dictionary…" or "Dictionary unavailable"))
            {
                SubtitleText.Text = "Loading dictionary…";
            }
        }
        else if (string.IsNullOrWhiteSpace(text))
        {
            SubtitleText.Text = "বাংলা বানান পরীক্ষক";
        }
        else if (issueCount == 0)
        {
            SubtitleText.Text = $"{words} words · all clear";
        }
        else
        {
            SubtitleText.Text = $"{words} words · {issueCount} issue{(issueCount == 1 ? string.Empty : "s")}";
        }

        if (issueCount == 0)
        {
            IssuesStatusIcon.Glyph = "\uE73E";
            IssuesStatusIcon.Foreground = (Brush)Application.Current.Resources["AppSuccessBrush"];
            IssuesStatusText.Text = "No issues";
            IssuesStatusText.Foreground = (Brush)Application.Current.Resources["AppSuccessBrush"];
        }
        else
        {
            IssuesStatusIcon.Glyph = "\uE7BA";
            IssuesStatusIcon.Foreground = (Brush)Application.Current.Resources["AppWarningBrush"];
            IssuesStatusText.Text = $"{issueCount} issue{(issueCount == 1 ? string.Empty : "s")}";
            IssuesStatusText.Foreground = (Brush)Application.Current.Resources["AppWarningBrush"];
        }

        var hasText = !string.IsNullOrEmpty(text);
        FixAllButton.IsEnabled = _checker.IsReady && _issues.Count > 0;
        CopyButton.IsEnabled = hasText;
        ClearButton.IsEnabled = hasText;
    }

    private static int CountWords(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return 0;
        }

        return System.Text.RegularExpressions.Regex.Matches(text, @"[\u0980-\u09FF]+").Count;
    }
}
