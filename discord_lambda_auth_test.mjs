import { verifyKey, InteractionType, InteractionResponseType } from 'discord-interactions';

export const handler = async (event) => {
    const PUBLIC_KEY = process.env.DISCORD_PUBLIC_KEY;
    
    // Headers can be lowercase or uppercase depending on your API Gateway setup
    const signature = event.headers['x-signature-ed25519'] || event.headers['X-Signature-Ed25519'];
    const timestamp = event.headers['x-signature-timestamp'] || event.headers['X-Signature-Timestamp'];
    const body = event.body;

    // 1. Verify the request (This is why Discord was failing you)
    const isValidRequest = verifyKey(body, signature, timestamp, PUBLIC_KEY);
    if (!isValidRequest) {
        return {
            statusCode: 401,
            body: JSON.stringify({ error: 'Invalid request signature' }),
        };
    }

    // 2. Parse the interaction
    const interaction = JSON.parse(body);

    // 3. Handle PING (InteractionType 1)
    if (interaction.type === InteractionType.PING) {
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: InteractionResponseType.PONG }),
        };
    }

    // 4. Handle Slash Commands (Example)
    if (interaction.type === InteractionType.APPLICATION_COMMAND) {
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                type: InteractionResponseType.CHANNEL_MESSAGE_WITH_SOURCE,
                data: { content: "Verification successful! The switch is ready." }
            }),
        };
    }

    return { statusCode: 400, body: 'Unknown interaction type' };
};
