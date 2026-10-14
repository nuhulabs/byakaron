/*
 * Byakaron Fcitx5 addon — a thin InputMethodEngineV2 around Core/composer.c.
 *
 * IBus (Keyboard/engine.c) and this file must not duplicate key policy. Space,
 * 1–9, digits, Escape, shortcuts all mean whatever the composer says; this
 * file only turns those outcomes into commitString / client preedit / panel
 * candidates.
 *
 * Optional: `zig build linux-fcitx5` (needs libfcitx5core-dev). IBus stays the
 * GNOME/Ubuntu default; this exists so a KDE box can load the same composer.
 */
#include "engine.h"

#include <fcitx-utils/key.h>
#include <fcitx-utils/macros.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/userinterface.h>

#include <glib.h>
#include <gio/gio.h>

#include "prefs.h"

#include <memory>
#include <string>
#include <utility>

namespace {

using fcitx::KeyState;
using fcitx::KeyStates;
using fcitx::TextFormatFlag;

static guint
byk_fcitx_mods (const fcitx::KeyEvent &event)
{
    guint mods = 0;
    if (event.isRelease ())
        mods |= BYK_MOD_RELEASE;

    const KeyStates st = event.rawKey ().states ();
    if (st.test (KeyState::Ctrl) || st.test (KeyState::Alt) ||
        st.test (KeyState::Super) || st.test (KeyState::Super2) ||
        st.test (KeyState::Hyper) || st.test (KeyState::Hyper2) ||
        st.test (KeyState::Meta))
        mods |= BYK_MOD_SHORTCUT;
    return mods;
}

class BykCandidateWord : public fcitx::CandidateWord {
public:
    BykCandidateWord (ByakaronEngine *engine, guint index, std::string text)
        : fcitx::CandidateWord (fcitx::Text (std::move (text))),
          engine_ (engine),
          index_ (index)
    {
    }

    void select (fcitx::InputContext *ic) const override
    {
        engine_->pick (ic, index_);
    }

private:
    ByakaronEngine *engine_;
    guint index_;
};

static GSettings *
byk_fcitx_prefs (void)
{
    static GSettings *prefs = nullptr;
    static gboolean tried = FALSE;
    if (!tried) {
        tried = TRUE;
        prefs = byk_prefs_try_open ();
    }
    return prefs;
}

} // namespace

ByakaronState::ByakaronState ()
    : composer (byk_composer_new ())
{
}

ByakaronState::~ByakaronState ()
{
    byk_composer_free (composer);
    composer = nullptr;
}

ByakaronEngine::ByakaronEngine (fcitx::Instance *instance)
    : instance_ (instance),
      factory_ ([] (fcitx::InputContext &) { return new ByakaronState; })
{
    instance_->inputContextManager ().registerProperty ("byakaronState",
                                                        &factory_);
}

void
ByakaronEngine::syncPanel (fcitx::InputContext *ic, ByakaronState *state)
{
    const gchar *latin = byk_composer_latin (state->composer);
    if (latin == nullptr || *latin == '\0') {
        ic->inputPanel ().reset ();
        ic->updatePreedit ();
        ic->updateUserInterface (fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    gchar *bangla = byk_composer_preedit (state->composer);
    fcitx::Text preedit (bangla ? bangla : "", TextFormatFlag::Underline);
    const int cursor = bangla ? static_cast<int> (g_utf8_strlen (bangla, -1)) : 0;
    preedit.setCursor (cursor);
    ic->inputPanel ().setClientPreedit (preedit);
    ic->inputPanel ().setPreedit (preedit);
    g_free (bangla);

    auto list = std::make_unique<fcitx::CommonCandidateList> ();
    list->setPageSize (BYK_COMPOSER_PAGE_SIZE);
    /* Number keys are handled in the composer so Fcitx must not steal 1–9. */
    list->setSelectionKey ({});
    const gboolean horiz =
        byk_prefs_boolean (byk_fcitx_prefs (), BYK_PREFS_CANDIDATES_HORIZONTAL, TRUE);
    list->setLayoutHint (horiz ? fcitx::CandidateLayoutHint::Horizontal
                               : fcitx::CandidateLayoutHint::Vertical);

    gchar **words = byk_composer_candidates (state->composer);
    if (words != nullptr) {
        const guint page = byk_composer_page (state->composer);
        const guint start = page * BYK_COMPOSER_PAGE_SIZE;
        for (guint i = 0; i < BYK_COMPOSER_PAGE_SIZE; i++) {
            if (words[start + i] == nullptr)
                break;
            list->append (std::make_unique<BykCandidateWord> (
                this, i, std::string (words[start + i])));
        }
    }

    /* Highlight only after an arrow key moved it (see byk_composer_cursor). */
    const gint cursor = byk_composer_cursor (state->composer);
    const gint first = static_cast<gint> (byk_composer_page (state->composer) * BYK_COMPOSER_PAGE_SIZE);
    if (cursor >= first && cursor - first < list->size ())
        list->setGlobalCursorIndex (cursor - first);
    else
        list->setGlobalCursorIndex (-1);

    if (list->size () == 0)
        ic->inputPanel ().setCandidateList (nullptr);
    else
        ic->inputPanel ().setCandidateList (std::move (list));

    ic->updatePreedit ();
    ic->updateUserInterface (fcitx::UserInterfaceComponent::InputPanel);
}

void
ByakaronEngine::apply (fcitx::InputContext *ic, ByakaronState *state,
                       BykOutcome outcome, fcitx::KeyEvent *keyEvent)
{
    switch (outcome.action) {
    case BYK_ACT_PASS:
        g_free (outcome.commit);
        return;

    case BYK_ACT_EAT:
        syncPanel (ic, state);
        g_free (outcome.commit);
        if (keyEvent != nullptr)
            keyEvent->filterAndAccept ();
        return;

    case BYK_ACT_COMMIT:
        /* Commit first, then clear preedit: same Electron/Monaco order as IBus. */
        if (outcome.commit != nullptr && outcome.commit[0] != '\0')
            ic->commitString (outcome.commit);
        ic->inputPanel ().reset ();
        ic->updatePreedit ();
        ic->updateUserInterface (fcitx::UserInterfaceComponent::InputPanel);
        g_free (outcome.commit);
        if (keyEvent != nullptr && !outcome.pass_key)
            keyEvent->filterAndAccept ();
        return;
    }

    g_free (outcome.commit);
}

void
ByakaronEngine::pick (fcitx::InputContext *ic, guint index)
{
    auto *state = ic->propertyFor (&factory_);
    apply (ic, state, byk_composer_select (state->composer, index), nullptr);
}

void
ByakaronEngine::keyEvent (const fcitx::InputMethodEntry &entry,
                          fcitx::KeyEvent &keyEvent)
{
    FCITX_UNUSED (entry);
    auto *ic = keyEvent.inputContext ();
    auto *state = ic->propertyFor (&factory_);
    byk_composer_set_phonetic_only (
        state->composer,
        byk_prefs_boolean (byk_fcitx_prefs (), BYK_PREFS_PHONETIC_ONLY, FALSE));
    const guint keyval = static_cast<guint> (keyEvent.key ().sym ());
    apply (ic, state,
           byk_composer_key (state->composer, keyval, byk_fcitx_mods (keyEvent)),
           &keyEvent);
}

void
ByakaronEngine::reset (const fcitx::InputMethodEntry &entry,
                       fcitx::InputContextEvent &event)
{
    FCITX_UNUSED (entry);
    auto *ic = event.inputContext ();
    auto *state = ic->propertyFor (&factory_);
    apply (ic, state, byk_composer_flush (state->composer), nullptr);
}

void
ByakaronEngine::deactivate (const fcitx::InputMethodEntry &entry,
                            fcitx::InputContextEvent &event)
{
    reset (entry, event);
}

fcitx::AddonInstance *
ByakaronEngineFactory::create (fcitx::AddonManager *manager)
{
    return new ByakaronEngine (manager->instance ());
}

FCITX_ADDON_FACTORY (ByakaronEngineFactory);
