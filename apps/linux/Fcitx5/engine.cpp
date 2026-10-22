/*
 * Byakaron Fcitx5 addon — a thin InputMethodEngineV2 around libbyakaron's
 * Composer (Core/composer.h), the same keyboard IBus and every other platform
 * drive. Space, 1–9, arrows, paging, Escape and shortcuts all mean whatever the
 * composer says; this file maps keysyms to composer keys and turns its results
 * and state into commitString / client preedit / panel candidates.
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
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/userinterface.h>

#include <glib.h>

#include <memory>
#include <string>
#include <utility>

namespace {

using fcitx::KeyState;
using fcitx::KeyStates;
using fcitx::TextFormatFlag;

static unsigned int
byk_fcitx_mods (const fcitx::KeyEvent &event)
{
    unsigned int mods = 0;
    const KeyStates st = event.rawKey ().states ();
    if (st.test (KeyState::Shift))
        mods |= BYAKARON_MOD_SHIFT;
    if (st.test (KeyState::Ctrl))
        mods |= BYAKARON_MOD_CTRL;
    if (st.test (KeyState::Alt))
        mods |= BYAKARON_MOD_ALT;
    if (st.test (KeyState::Super) || st.test (KeyState::Super2) ||
        st.test (KeyState::Hyper) || st.test (KeyState::Hyper2) ||
        st.test (KeyState::Meta))
        mods |= BYAKARON_MOD_META;
    return mods;
}

class BykCandidateWord : public fcitx::CandidateWord {
public:
    BykCandidateWord (ByakaronEngine *engine, size_t index, std::string text)
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
    size_t index_;
};

} // namespace

ByakaronEngine::ByakaronEngine (fcitx::Instance *instance)
    : instance_ (instance)
{
    dispatcher_.attach (&instance_->eventLoop ());
    composer_ = byk_composer_open (TRUE, &ByakaronEngine::onUpdate, this);
}

ByakaronEngine::~ByakaronEngine ()
{
    /* First: it stops the worker that calls onUpdate. */
    byakaron_composer_destroy (composer_);
    composer_ = nullptr;
    dispatcher_.detach ();
}

/* The composer's worker thread: corrections arrived. Refresh on the event
 * loop, where the composer lives. */
void
ByakaronEngine::onUpdate (void *userdata)
{
    auto *self = static_cast<ByakaronEngine *> (userdata);
    self->dispatcher_.schedule ([self] () {
        if (self->composer_ == nullptr)
            return;
        byakaron_composer_refresh (self->composer_);
        if (auto *ic = self->owner_.get ())
            self->redraw (ic);
    });
}

/* Draw the composer's state: the highlighted candidate inline, the current
 * page in the panel. */
void
ByakaronEngine::redraw (fcitx::InputContext *ic)
{
    ByakaronComposerState st;
    byakaron_composer_state (composer_, &st);

    ic->inputPanel ().reset ();
    if (st.composing && st.preedit[0] != '\0') {
        fcitx::Text preedit (st.preedit, TextFormatFlag::Underline);
        preedit.setCursor (static_cast<int> (g_utf8_strlen (st.preedit, -1)));
        ic->inputPanel ().setClientPreedit (preedit);
        ic->inputPanel ().setPreedit (preedit);
    }

    if (st.panel_visible && st.candidate_count > 0) {
        auto list = std::make_unique<fcitx::CommonCandidateList> ();
        list->setPageSize (static_cast<int> (st.candidate_count));
        /* 1–9 are composer keys: Fcitx must not steal them. */
        list->setSelectionKey ({});
        list->setLayoutHint (st.vertical ? fcitx::CandidateLayoutHint::Vertical
                                         : fcitx::CandidateLayoutHint::Horizontal);
        for (size_t i = 0; i < st.candidate_count; i++)
            list->append (std::make_unique<BykCandidateWord> (
                this, i, std::string (st.candidates[i])));
        list->setGlobalCursorIndex (static_cast<int> (st.highlight));
        ic->inputPanel ().setCandidateList (std::move (list));
    }

    ic->updatePreedit ();
    ic->updateUserInterface (fcitx::UserInterfaceComponent::InputPanel);
}

/* Insert the commit, then redraw (which clears the preedit): the same
 * Electron/Monaco order as IBus. Returns whether the key was consumed. */
bool
ByakaronEngine::apply (fcitx::InputContext *ic, ByakaronKeyResult result)
{
    if (result.commit != nullptr && result.commit[0] != '\0')
        ic->commitString (result.commit);
    redraw (ic);
    return result.handled != 0;
}

/* Focus left `ic` (or it was reset): insert the pending word there. */
void
ByakaronEngine::flush (fcitx::InputContext *ic)
{
    if (composer_ == nullptr)
        return;
    const char *text = byakaron_composer_flush (composer_);
    if (text != nullptr && text[0] != '\0')
        ic->commitString (text);
    redraw (ic);
}

void
ByakaronEngine::pick (fcitx::InputContext *ic, size_t index)
{
    if (composer_ != nullptr)
        apply (ic, byakaron_composer_pick (composer_, index));
}

void
ByakaronEngine::keyEvent (const fcitx::InputMethodEntry &entry,
                          fcitx::KeyEvent &keyEvent)
{
    FCITX_UNUSED (entry);
    auto *ic = keyEvent.inputContext ();
    int kind;
    unsigned int ch;
    /* Releases never reach the composer; pure modifier keys are not sent. */
    if (composer_ == nullptr || keyEvent.isRelease () ||
        !byk_keysym_to_key (static_cast<guint> (keyEvent.key ().sym ()), &kind, &ch))
        return;

    /* A word left pending in another context belongs there, not here. */
    auto *owner = owner_.get ();
    if (owner != nullptr && owner != ic)
        flush (owner);
    owner_ = ic->watch ();

    if (apply (ic, byakaron_composer_key (composer_, kind, ch, byk_fcitx_mods (keyEvent))))
        keyEvent.filterAndAccept ();
}

void
ByakaronEngine::reset (const fcitx::InputMethodEntry &entry,
                       fcitx::InputContextEvent &event)
{
    FCITX_UNUSED (entry);
    auto *ic = event.inputContext ();
    /* Fcitx5 does not commit the preedit by itself (unlike IBus's
     * PREEDIT_COMMIT), so the composer's flush text is inserted here. */
    if (owner_.get () == ic)
        flush (ic);
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
