import { adoptRoute, adoptEnv } from "../../lib/adopt.js";
export const onRequestGet = ({ params, waitUntil, env }) => (adoptEnv(env), adoptRoute(Array.isArray(params.p) ? params.p : (params.p ? [params.p] : []), waitUntil));
