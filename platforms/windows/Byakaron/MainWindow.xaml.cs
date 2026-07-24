using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.RegularExpressions;
using Byakaron.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Byakaron
{
    public sealed partial class MainWindow : Window
    {
        private readonly ObservableCollection<SpellIssue> _issues = new();
        private bool _sidebarVisible = true;
        private bool _suppressEditorSync;

        // Demo dictionary: incorrect → suggestions (UI shell until FFI is wired).
        private static readonly Dictionary<string, string[]> DemoCorrections = new(StringComparer.Ordinal)
        {
            ["গিয়ে"] = ["গিয়ে", "গিয়েছি", "গিয়েছিল"],
            ["হয়ে"] = ["হয়ে", "হয়েছে", "হয়েছিল"],
            ["দিয়ে"] = ["দিয়ে", "দিয়েছে", "দিয়েছিল"],
            ["করে"] = ["করে", "করেছে", "করবে"],
            ["বাংলায়"] = ["বাংলায়", "বাংলা", "বাংলায়ই"],
            ["বাংলায"] = ["বাংলায়", "বাংলা"],
            ["সকসমসকসম"] = ["সমস্যা", "সক্ষম", "সমসম"],
            ["সহমস"] = ["সমস্যা", "সহমত", "সহমর্মী"],
        };

        private static readonly string SampleText =
            "আমি বাংলায় লিখি। গিয়ে দেখি নদী বয়ে চলে। হয়ে যায় সন্ধ্যা, দিয়ে রাখি বাতি। " +
            "কিছু শব্দ ভুল থাকতে পারে — সকসমসকসম আর সহমস — যা পরীক্ষক ধরবে।";

        public MainWindow()
        {
            InitializeComponent();

            ExtendsContentIntoTitleBar = true;
            SetTitleBar(AppTitleBar);

            IssuesList.ItemsSource = _issues;

            _suppressEditorSync = true;
            EditorTextBox.Text = SampleText;
            _suppressEditorSync = false;

            RescanDocument();
            if (_issues.Count > 0)
            {
                IssuesList.SelectedIndex = 0;
            }
        }

        private void SidebarToggleButton_Click(object sender, RoutedEventArgs e)
        {
            _sidebarVisible = !_sidebarVisible;
            SidebarColumn.Width = _sidebarVisible
                ? new GridLength(268)
                : new GridLength(0);
            SidebarPane.Visibility = _sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        }

        private void EditorTextBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (_suppressEditorSync)
            {
                return;
            }

            RescanDocument();
        }

        private void IssuesList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            UpdateCorrectionBar();
        }

        private void FixAllButton_Click(object sender, RoutedEventArgs e)
        {
            if (_issues.Count == 0)
            {
                return;
            }

            var text = EditorTextBox.Text ?? string.Empty;
            // Apply from end to start so earlier offsets stay valid.
            foreach (var issue in _issues.OrderByDescending(i => i.Offset).ToList())
            {
                var replacement = issue.Suggestions.FirstOrDefault();
                if (string.IsNullOrEmpty(replacement))
                {
                    continue;
                }

                if (issue.Offset < 0 || issue.Offset + issue.Length > text.Length)
                {
                    continue;
                }

                text = string.Concat(
                    text.AsSpan(0, issue.Offset),
                    replacement,
                    text.AsSpan(issue.Offset + issue.Length));
            }

            _suppressEditorSync = true;
            EditorTextBox.Text = text;
            _suppressEditorSync = false;
            RescanDocument();
        }

        private void CopyButton_Click(object sender, RoutedEventArgs e)
        {
            var text = EditorTextBox.Text ?? string.Empty;
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
            _suppressEditorSync = true;
            EditorTextBox.Text = string.Empty;
            _suppressEditorSync = false;
            _issues.Clear();
            IssuesList.SelectedItem = null;
            UpdateCorrectionBar();
            UpdateChrome();
        }

        private void IgnoreButton_Click(object sender, RoutedEventArgs e)
        {
            if (IssuesList.SelectedItem is not SpellIssue selected)
            {
                return;
            }

            var index = _issues.IndexOf(selected);
            _issues.Remove(selected);

            if (_issues.Count == 0)
            {
                IssuesList.SelectedItem = null;
            }
            else
            {
                IssuesList.SelectedIndex = Math.Min(index, _issues.Count - 1);
            }

            UpdateCorrectionBar();
            UpdateChrome();
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

            var text = EditorTextBox.Text ?? string.Empty;
            if (selected.Offset < 0 || selected.Offset + selected.Length > text.Length)
            {
                return;
            }

            var nextOffset = selected.Offset + replacement.Length;
            text = string.Concat(
                text.AsSpan(0, selected.Offset),
                replacement,
                text.AsSpan(selected.Offset + selected.Length));

            _suppressEditorSync = true;
            EditorTextBox.Text = text;
            _suppressEditorSync = false;

            RescanDocument();

            var next = _issues.FirstOrDefault(i => i.Offset >= nextOffset) ?? _issues.FirstOrDefault();
            IssuesList.SelectedItem = next;
        }

        private void RescanDocument()
        {
            var text = EditorTextBox.Text ?? string.Empty;
            var previousId = (IssuesList.SelectedItem as SpellIssue)?.Id;

            _issues.Clear();

            foreach (Match match in BengaliWordRegex().Matches(text))
            {
                if (!DemoCorrections.TryGetValue(match.Value, out var suggestions))
                {
                    continue;
                }

                // Skip "correct" forms that are also dictionary keys used as suggestions.
                if (suggestions.Length > 0 &&
                    string.Equals(match.Value, suggestions[0], StringComparison.Ordinal))
                {
                    continue;
                }

                _issues.Add(new SpellIssue
                {
                    Id = $"{match.Index}:{match.Value}",
                    Word = match.Value,
                    Suggestions = suggestions,
                    Offset = match.Index,
                });
            }

            if (previousId is not null)
            {
                var stillThere = _issues.FirstOrDefault(i => i.Id == previousId);
                IssuesList.SelectedItem = stillThere ?? _issues.FirstOrDefault();
            }
            else if (_issues.Count > 0 && IssuesList.SelectedItem is null)
            {
                IssuesList.SelectedIndex = 0;
            }

            UpdateCorrectionBar();
            UpdateChrome();
        }

        private void UpdateCorrectionBar()
        {
            SuggestionsPanel.Children.Clear();

            if (IssuesList.SelectedItem is not SpellIssue issue)
            {
                CorrectionBar.Visibility = Visibility.Collapsed;
                return;
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
            var text = EditorTextBox.Text ?? string.Empty;
            var words = CountWords(text);
            var chars = text.Length;
            var issueCount = _issues.Count;

            WordCountText.Text = $"{words} word{(words == 1 ? string.Empty : "s")}";
            CharCountText.Text = $"{chars} character{(chars == 1 ? string.Empty : "s")}";

            IssuesHeaderText.Text = issueCount == 0 ? "Issues" : $"Issues ({issueCount})";

            if (string.IsNullOrWhiteSpace(text))
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
            var canFix = _issues.Any(i => i.Suggestions.Count > 0);
            FixAllButton.IsEnabled = canFix;
            CopyButton.IsEnabled = hasText;
            ClearButton.IsEnabled = hasText;
        }

        private static int CountWords(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return 0;
            }

            return BengaliWordRegex().Matches(text).Count;
        }

        [GeneratedRegex(@"[\u0980-\u09FF]+", RegexOptions.Compiled)]
        private static partial Regex BengaliWordRegex();
    }
}
