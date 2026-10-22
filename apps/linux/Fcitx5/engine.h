#ifndef BYAKARON_LINUX_FCITX5_ENGINE_H
#define BYAKARON_LINUX_FCITX5_ENGINE_H

#include "composer.h"

#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/addonfactory.h>
#include <fcitx/inputmethodengine.h>

namespace fcitx {
class Instance;
class InputContext;
class KeyEvent;
class InputContextEvent;
class InputMethodEntry;
class AddonManager;
}

class ByakaronEngine : public fcitx::InputMethodEngineV2 {
public:
    explicit ByakaronEngine (fcitx::Instance *instance);
    ~ByakaronEngine () override;

    void keyEvent (const fcitx::InputMethodEntry &entry,
                   fcitx::KeyEvent &keyEvent) override;
    void reset (const fcitx::InputMethodEntry &entry,
                fcitx::InputContextEvent &event) override;
    void deactivate (const fcitx::InputMethodEntry &entry,
                     fcitx::InputContextEvent &event) override;

    void pick (fcitx::InputContext *ic, size_t index);

private:
    static void onUpdate (void *userdata);
    void redraw (fcitx::InputContext *ic);
    bool apply (fcitx::InputContext *ic, ByakaronKeyResult result);
    void flush (fcitx::InputContext *ic);

    fcitx::Instance *instance_;
    /* One composer for the whole addon: only the focused input context types,
     * and a word is flushed when its context loses focus. NULL if it could not
     * be created (keys then pass). */
    ByakaronComposer *composer_;
    /* The context the pending word belongs to, for redraws after on_update. */
    fcitx::TrackableObjectReference<fcitx::InputContext> owner_;
    /* Hops on_update from the composer's worker thread to the event loop. */
    fcitx::EventDispatcher dispatcher_;
};

class ByakaronEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create (fcitx::AddonManager *manager) override;
};

#endif /* BYAKARON_LINUX_FCITX5_ENGINE_H */
