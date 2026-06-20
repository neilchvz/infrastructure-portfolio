import axios from 'axios';

const API_KEY = process.env.UPTIMEROBOT_API_KEY;

export interface Monitor {
  id: number;
  friendly_name: string;
  status: number;
}

// Status codes: 0 = paused, 1 = not checked yet,
// 2 = up, 8 = seems down, 9 = down

export async function getMonitors(): Promise<Monitor[]> {
  const response = await axios.post(
    'https://api.uptimerobot.com/v2/getMonitors',
    `api_key=${API_KEY}&format=json`,
    {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    }
  );

  if (response.data.stat !== 'ok') {
    throw new Error(`UptimeRobot API error: ${JSON.stringify(response.data)}`);
  }

  return response.data.monitors;
}
