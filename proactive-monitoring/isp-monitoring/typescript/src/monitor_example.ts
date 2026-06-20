import { getMonitors } from './uptimerobot_example';
import { findOpenTicket, closeTicket } from './connectwise_example';

export async function pollAndClose(): Promise<void> {
  console.log(`[${new Date().toISOString()}] Polling...`);

  try {
    const monitors = await getMonitors();

    for (const monitor of monitors) {
      const isDown = monitor.status === 8 || monitor.status === 9;
      const isUp = monitor.status === 2;

      if (isDown) {
        console.log(`[DOWN] ${monitor.friendly_name}`);
      }

      if (isUp) {
        // No local state tracking, every poll checks the PSA directly.
        // See the README for why this replaced an earlier in-memory approach.
        const ticket = await findOpenTicket(monitor.friendly_name);

        if (ticket) {
          console.log(`[RECOVERED] ${monitor.friendly_name} — closing ticket #${ticket.id}`);
          await closeTicket(ticket.id, monitor.friendly_name);
        } else {
          console.log(`[UP] ${monitor.friendly_name}`);
        }
      }
    }
  } catch (err) {
    console.error('[ERROR] Poll failed:', err);
  }
}
