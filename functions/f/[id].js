import { foundShare } from "../../lib/share.js";
export const onRequest = ({ params }) => foundShare(params.id);
