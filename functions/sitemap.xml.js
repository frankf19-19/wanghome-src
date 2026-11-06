import { sitemap } from "../lib/seo.js";
export const onRequestGet = ({ waitUntil }) => sitemap(waitUntil);
