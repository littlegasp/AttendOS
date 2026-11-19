"""Catches the e-mails Supabase Auth sends during the local check and saves each one as JSON in ./mail/."""
import asyncio, email, json, os, sys, time
from email import policy
from aiosmtpd.controller import Controller

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mail")
os.makedirs(OUT, exist_ok=True)

class Sink:
    async def handle_DATA(self, server, session, envelope):
        msg = email.message_from_bytes(envelope.content, policy=policy.default)
        body = msg.get_body(preferencelist=("html", "plain"))
        rec = {"to": envelope.rcpt_tos, "subject": str(msg["subject"]), "body": body.get_content() if body else ""}
        with open(os.path.join(OUT, f"{time.time():.6f}.json"), "w") as f:
            json.dump(rec, f)
        return "250 OK"

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 2525
    Controller(Sink(), hostname="127.0.0.1", port=port).start()
    asyncio.get_event_loop().run_forever()
