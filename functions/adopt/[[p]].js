import { adoptRoute } from "../../lib/adopt.js";
export const onRequestGet = ({ params, waitUntil }) => adoptRoute(Array.isArray(params.p) ? params.p : (params.p ? [params.p] : []), waitUntil);
