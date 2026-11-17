import { Hono } from "hono";

type App = { Bindings: Env };

const app = new Hono<App>();

// Hono's default handler prints the error. The relay prints nothing.
app.onError((_error, c) => c.body(null, 500));

app.get("/version", (c) => c.json({ commit: c.env.COMMIT }));

export default app;
