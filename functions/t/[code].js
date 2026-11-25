import { tagPage } from "../../lib/tag.js";
export const onRequestGet = ({ params }) => tagPage(params.code);
