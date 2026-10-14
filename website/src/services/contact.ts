import nodemailer from "nodemailer";
import type { AppConfig } from "../config.js";

export type ContactMessage = {
  name: string;
  email: string;
  subject: string;
  message: string;
};

export type ContactMailer = {
  send(message: ContactMessage): Promise<void>;
};

export function createContactMailer(config: AppConfig): ContactMailer | undefined {
  if (!config.smtp) return undefined;

  // The transporter is created once at startup and reused for incoming messages.
  // SMTP credentials remain server-only environment variables.
  const transporter = nodemailer.createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    secure: config.smtp.secure,
    auth: { user: config.smtp.user, pass: config.smtp.pass },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000
  });

  return {
    async send(message) {
      await transporter.sendMail({
        from: config.smtp!.from,
        to: config.contactToEmail,
        replyTo: { name: message.name, address: message.email },
        // Keep the visitor's subject intact. Mail clients will use it for a natural
        // "Re: <subject>" conversation when support replies.
        subject: message.subject,
        text: [
          `Name: ${message.name}`,
          `Email: ${message.email}`,
          `Subject: ${message.subject}`,
          "",
          "Message:",
          message.message
        ].join("\n"),
        // Disable file/URL access so visitors cannot coerce the mailer into reading server files.
        disableFileAccess: true,
        disableUrlAccess: true
      });
    }
  };
}
