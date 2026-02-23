import { verifyKey, InteractionType, InteractionResponseType } from 'discord-interactions';
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";

const lambdaClient = new LambdaClient({ region: process.env.AWS_REGION || 'us-east-1' });

export const handler = async (event) => {
    // 1. Configuration from Environment Variables
    const PUBLIC_KEY = process.env.DISCORD_PUBLIC_KEY;
    const WORKER_LAMBDA_ARN = process.env.WORKER_LAMBDA_ARN; // Formally Lambda B
    const TRIGGER_COMMAND = process.env.TRIGGER_COMMAND || 'start';

    const signature = event.headers['x-signature-ed25519'] || event.headers['X-Signature-Ed25519'];
    const timestamp = event.headers['x-signature-timestamp'] || event.headers['X-Signature-Timestamp'];
    const body = event.body;

    // 2. Verify Security Signature
    const isValidRequest = await verifyKey(body, signature, timestamp, PUBLIC_KEY);

    if (!isValidRequest) {
        console.error("Invalid request signature.");
        return { statusCode: 401, body: JSON.stringify({ error: 'Invalid request signature' }) };
    }

    const interaction = JSON.parse(body);

    // 3. Handle Discord PING (Required for Webhook registration)
    if (interaction.type === InteractionType.PING) {
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: InteractionResponseType.PONG }),
        };
    }

    // 4. Handle Application Commands
    if (interaction.type === InteractionType.APPLICATION_COMMAND) {
        const commandName = interaction.data?.name;

        if (commandName === TRIGGER_COMMAND) {
            const payload = JSON.stringify({ 
                user: interaction.member?.user?.username || "Unknown User",
                interactionId: interaction.id,
                command: commandName
            });

            const command = new InvokeCommand({
                FunctionName: WORKER_LAMBDA_ARN,
                InvocationType: 'Event', // Asynchronous execution
                Payload: new TextEncoder().encode(payload),
            });

            try {
                await lambdaClient.send(command);
                console.log(`Worker Lambda triggered successfully.`);
            } catch (err) {
                console.error("Error triggering Worker Lambda:", err);
            }

            // Respond to Discord immediately (must be within 3 seconds)
            return {
                statusCode: 200,
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    type: InteractionResponseType.CHANNEL_MESSAGE_WITH_SOURCE,
                    data: { content: "Process initiated. Please wait..." }
                }),
            };
        }
    }

    return { statusCode: 400, body: JSON.stringify({ error: 'Unhandled interaction' }) };
};
