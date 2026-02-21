import { verifyKey, InteractionType, InteractionResponseType } from 'discord-interactions';

export const handler = async (event) => {
  console.log('--- INTERACTION START ---');

  const PUBLIC_KEY = process.env.DISCORD_PUBLIC_KEY;

  const signature =
    event.headers['x-signature-ed25519'] ||
    event.headers['X-Signature-Ed25519'];

  const timestamp =
    event.headers['x-signature-timestamp'] ||
    event.headers['X-Signature-Timestamp'];

  const body = event.body;

  console.log(`Key Configured: ${!!PUBLIC_KEY}`);
  console.log(`Headers - Signature: ${!!signature}, Timestamp: ${!!timestamp}`);
  console.log(`Body Type: ${typeof body}`);

  let isValidRequest = false;

  try {
    if (PUBLIC_KEY && signature && timestamp) {
      isValidRequest = await verifyKey(body, signature, timestamp, PUBLIC_KEY);
    }
  } catch (err) {
    console.error('Verification Error:', err);
  }

  console.log('Verification Result:', isValidRequest);

  if (!isValidRequest) {
    console.error('Authentication Failed: Invalid Discord Signature');
    return {
      statusCode: 401,
      body: JSON.stringify({ error: 'Invalid request signature' }),
    };
  }

  const interaction = JSON.parse(body);

  if (interaction.type === InteractionType.PING) {
    console.log('Handling PING - Sending PONG');
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: InteractionResponseType.PONG }),
    };
  }

  if (interaction.type === InteractionType.APPLICATION_COMMAND) {
    console.log(`Handling Command: ${interaction.data?.name}`);
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: InteractionResponseType.CHANNEL_MESSAGE_WITH_SOURCE,
        data: {
          content: 'Verification successful! The switch is ready.',
        },
      }),
    };
  }

  return {
    statusCode: 400,
    body: JSON.stringify({ error: 'Unknown interaction type' }),
  };
};
