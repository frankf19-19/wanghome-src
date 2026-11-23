import { statsJson } from "../lib/stats.js";
export const onRequestGet = ({ waitUntil }) => statsJson(waitUntil);
