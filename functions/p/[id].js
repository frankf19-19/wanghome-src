import { casePage } from "../../lib/seo.js";
export const onRequestGet = ({ params }) => casePage(params.id);
