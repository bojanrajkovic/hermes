import { Hono } from "hono";

const app = new Hono<{ Bindings: Env }>();

app.get("/version", (c) => c.json({ commit: c.env.COMMIT }));

export default app;
