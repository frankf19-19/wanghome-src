import { friendInvite } from "../../lib/share.js";
export const onRequest = ({ params }) => friendInvite(params.code);
