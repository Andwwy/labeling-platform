import { next } from '@vercel/edge';

const PASSWORD = process.env.LABELING_PASSWORD || 'ritw';

export default function middleware(req) {
  const auth = req.headers.get('authorization');
  if (auth?.startsWith('Basic ')) {
    const decoded = atob(auth.slice(6));
    // username can be anything — we only check the password
    const password = decoded.split(':').slice(1).join(':');
    if (password === PASSWORD) return next();
  }
  return new Response('Authentication required', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="Rules Labeling"' },
  });
}

export const config = { matcher: '/((?!_vercel|favicon.ico).*)' };
