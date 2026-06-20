import dotenv from 'dotenv';
import { pollAndClose } from './monitor_example';

dotenv.config();

const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '300000');

console.log('ISP Monitor Closer started');
console.log(`Polling every ${POLL_INTERVAL_MS / 1000} seconds`);

// Run immediately on startup, then on a fixed interval.
// No initialization step here deliberately, see the README for why
// state is never tracked between polls.
pollAndClose();
setInterval(pollAndClose, POLL_INTERVAL_MS);
