import axios from 'axios';

const BASE_URL = process.env.CW_BASE_URL;
const COMPANY = process.env.CW_COMPANY;
const PUBLIC_KEY = process.env.CW_PUBLIC_KEY;
const PRIVATE_KEY = process.env.CW_PRIVATE_KEY;
const CLIENT_ID = process.env.CW_CLIENT_ID;

// Closed status ID is scoped per board. This value will be different
// depending on which board your tickets land on, see the README.
const CLOSED_STATUS_ID = 653;

function getAuthHeader(): string {
  const credentials = Buffer.from(`${COMPANY}+${PUBLIC_KEY}:${PRIVATE_KEY}`).toString('base64');
  return `Basic ${credentials}`;
}

const headers = {
  Authorization: getAuthHeader(),
  clientId: CLIENT_ID,
  'Content-Type': 'application/json',
};

export interface Ticket {
  id: number;
  summary: string;
}

export async function findOpenTicket(friendlyName: string): Promise<Ticket | null> {
  // Square brackets in the friendly name don't filter reliably through
  // the query API, so the search is intentionally broad and the
  // precise match happens in code below.
  const conditions = encodeURIComponent(
    `summary contains "Monitor is DOWN" AND closedFlag=false`
  );

  const response = await axios.get(
    `${BASE_URL}/service/tickets?conditions=${conditions}&pageSize=50`,
    { headers }
  );

  const tickets = response.data as Ticket[];
  const match = tickets.find(t => t.summary.includes(friendlyName));
  return match || null;
}

export async function addTicketNote(ticketId: number, friendlyName: string): Promise<void> {
  const ispMatch = friendlyName.match(/\|\s*(.+?)\]/);
  const ispName = ispMatch ? ispMatch[1].trim() : 'Unknown ISP';

  const companyMatch = friendlyName.match(/Company:\s*(.+?)\s*[\|]/);
  const companyName = companyMatch ? companyMatch[1].trim() : 'Unknown Company';

  const timestamp = new Date().toISOString();

  const noteText = `ISP monitor recovered automatically.

Monitor: ${friendlyName}
Company: ${companyName}
ISP Circuit: ${ispName}
Status: Back online
Detected by: UptimeRobot
Closed by: ISP Monitor Closer (automated)
Time: ${timestamp}

No action required. This ticket was opened and closed automatically by the monitoring system.`;

  await axios.post(
    `${BASE_URL}/service/tickets/${ticketId}/notes`,
    {
      text: noteText,
      detailDescriptionFlag: false,
      internalAnalysisFlag: true,
      resolutionFlag: true,
    },
    { headers }
  );
}

export async function closeTicket(ticketId: number, friendlyName: string): Promise<void> {
  await addTicketNote(ticketId, friendlyName);

  // Closing a ticket requires JSON Patch array format, not a plain object.
  // A plain {"status": {"id": X}} body gets rejected.
  await axios.patch(
    `${BASE_URL}/service/tickets/${ticketId}`,
    [{ op: 'replace', path: '/status', value: { id: CLOSED_STATUS_ID } }],
    { headers }
  );

  console.log(`[CLOSED] Ticket #${ticketId} closed for ${friendlyName}`);
}
