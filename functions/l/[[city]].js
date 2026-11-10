import { cityPage } from "../../lib/seo.js";
export const onRequestGet = ({ params }) => cityPage(params.city);
