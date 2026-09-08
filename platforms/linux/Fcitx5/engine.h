#ifndef BYAKARON_LINUX_FCITX5_ENGINE_H
#define BYAKARON_LINUX_FCITX5_ENGINE_H

#include "composer.h"

#include <fcitx/addonfactory.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>

namespace fcitx {
class Instance;
class InputContext;
class KeyEvent;
class InputContextEvent;
class InputMethodEntry;
class AddonManager;
}

class ByakaronEngine;

class ByakaronState : public fcitx::InputContextProperty {
public:
    ByakaronState ();
    ~ByakaronState () override;
    BykComposer *composer;
};

class ByakaronEngine : public fcitx::InputMethodEngineV2 {
public:
    explicit ByakaronEngine (fcitx::Instance *instance);

    void keyEvent (const fcitx::InputMethodEntry &entry,
                   fcitx::KeyEvent &keyEvent) override;
    void reset (const fcitx::InputMethodEntry &entry,
                fcitx::InputContextEvent &event) override;
    void deactivate (const fcitx::InputMethodEntry &entry,
                     fcitx::InputContextEvent &event) override;

    void pick (fcitx::InputContext *ic, guint index);

private:
    void syncPanel (fcitx::InputContext *ic, ByakaronState *state);
    void apply (fcitx::InputContext *ic, ByakaronState *state, BykOutcome outcome,
                fcitx::KeyEvent *keyEvent);

    fcitx::Instance *instance_;
    fcitx::FactoryFor<ByakaronState> factory_;
};

class ByakaronEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create (fcitx::AddonManager *manager) override;
};

#endif /* BYAKARON_LINUX_FCITX5_ENGINE_H */
