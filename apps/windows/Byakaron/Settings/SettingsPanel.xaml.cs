using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Byakaron.Settings;

public sealed partial class SettingsPanel : UserControl
{
    private bool _loading = true;

    public SettingsPanel()
    {
        InitializeComponent();
        LoadFromStore();
        _loading = false;
    }

    private void LoadFromStore()
    {
        PhoneticOnlyToggle.IsOn = ByakaronSettings.PhoneticOnlyMode;
        OrientationCombo.SelectedIndex = ByakaronSettings.OrientationVertical ? 1 : 0;
        PerPageSlider.Value = ByakaronSettings.CandidatesPerPage;
        PerPageValueText.Text = $"{ByakaronSettings.CandidatesPerPage} suggestions";
    }

    private void PhoneticOnlyToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        ByakaronSettings.PhoneticOnlyMode = PhoneticOnlyToggle.IsOn;
    }

    private void OrientationCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (OrientationCombo.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            ByakaronSettings.CandidateOrientation = tag;
        }
    }

    private void PerPageSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_loading || PerPageValueText is null) return;
        var n = (int)PerPageSlider.Value;
        ByakaronSettings.CandidatesPerPage = n;
        PerPageValueText.Text = $"{n} suggestions";
    }
}
