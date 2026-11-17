import { cityPage } from "../../lib/seo.js";
import { adoptEnv } from "../../lib/adopt.js";
export const onRequestGet = ({ params, env, waitUntil }) => { adoptEnv(env); return cityPage(params.city, waitUntil); };
