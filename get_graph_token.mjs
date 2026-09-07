import fs from 'fs';
import crypto from 'crypto';

const tenantId = process.env.TENANT_ID;
const clientId = process.env.CLIENT_ID;

if (!tenantId || !clientId) {
  console.error('TENANT_ID or CLIENT_ID is not set.');
  process.exit(1);
}

const keyPath =
  process.env.HOME +
  '/.autumn-solutions/graph-auth/AutumnGraphAutomation.key';

const certPath =
  process.env.HOME +
  '/.autumn-solutions/graph-auth/AutumnGraphAutomation.pem';

const privateKey = fs.readFileSync(keyPath);
const cert = new crypto.X509Certificate(
  fs.readFileSync(certPath, 'utf8')
);

const base64url = (input) =>
  Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');

const thumbprint = base64url(
  crypto.createHash('sha256').update(cert.raw).digest()
);

const tokenEndpoint =
  `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`;

const now = Math.floor(Date.now() / 1000);

const header = {
  alg: 'PS256',
  typ: 'JWT',
  'x5t#S256': thumbprint
};

const payload = {
  aud: tokenEndpoint,
  iss: clientId,
  sub: clientId,
  jti: crypto.randomUUID(),
  nbf: now,
  exp: now + 600
};

const encodedHeader = base64url(JSON.stringify(header));
const encodedPayload = base64url(JSON.stringify(payload));
const unsignedAssertion = `${encodedHeader}.${encodedPayload}`;

const signature = crypto.sign(
  'sha256',
  Buffer.from(unsignedAssertion),
  {
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  }
);

const assertion =
  `${unsignedAssertion}.${base64url(signature)}`;

const body = new URLSearchParams({
  client_id: clientId,
  scope: 'https://graph.microsoft.com/.default',
  grant_type: 'client_credentials',
  client_assertion_type:
    'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
  client_assertion: assertion
});

const response = await fetch(tokenEndpoint, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded'
  },
  body
});

const data = await response.json();

if (!response.ok || !data.access_token) {
  console.error(
    data.error_description ||
    data.error ||
    'Certificate authentication failed.'
  );
  process.exit(1);
}

process.stdout.write(data.access_token);
