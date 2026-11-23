import { statsPage } from "../lib/stats.js";
export const onRequestGet = ({ waitUntil }) => statsPage(waitUntil);
