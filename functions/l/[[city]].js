import { cityPage } from "../../lib/seo.js";
export const onRequestGet = ({ params }) => cityPage(Array.isArray(params.city) ? params.city[0] : params.city, Array.isArray(params.city) && params.city.length > 1);
