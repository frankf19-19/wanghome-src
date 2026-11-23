import { rehomeIndex, rehomePage } from "../../lib/seo.js";
export const onRequestGet = ({ params }) => { const p = [].concat(params.id || []).filter(Boolean); return p.length ? rehomePage(p[0]) : rehomeIndex(); };
