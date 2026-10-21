/*
 * BykEngine — the IBus engine that turns latin keystrokes into Bangla.
 *
 * Declared with the classic GObject boilerplate rather than
 * G_DECLARE_FINAL_TYPE: that macro chains up to the parent's autoptr cleanup
 * function, and IBus does not define one for IBusEngine. This is also the shape
 * IBus's own engines use, so it stays valid across ibus versions.
 */
#ifndef BYAKARON_LINUX_ENGINE_H
#define BYAKARON_LINUX_ENGINE_H

#include <ibus.h>

G_BEGIN_DECLS

#define BYK_TYPE_ENGINE     (byk_engine_get_type ())
#define BYK_ENGINE(obj)     (G_TYPE_CHECK_INSTANCE_CAST ((obj), BYK_TYPE_ENGINE, BykEngine))
#define BYK_IS_ENGINE(obj)  (G_TYPE_CHECK_INSTANCE_TYPE ((obj), BYK_TYPE_ENGINE))

typedef struct _BykEngine BykEngine;
typedef struct _BykEngineClass BykEngineClass;

struct _BykEngineClass {
    IBusEngineClass parent_class;
};

GType byk_engine_get_type (void) G_GNUC_CONST;

G_END_DECLS

#endif /* BYAKARON_LINUX_ENGINE_H */
