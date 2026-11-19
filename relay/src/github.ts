import { request } from "@octokit/request";
import { z } from "zod";
import type { Registration } from "./registration";

type AppCredentials = Pick<Registration, "clientID" | "clientSecret">;

/** GitHub's answer to a code. It answers 200 with an `error` field when it refuses. */
const TokenAnswer = z.object({
  refresh_token: z.unknown().optional(),
  error: z.unknown().optional(),
});

/**
 * Trades the code GitHub gave the browser at sign-in for the user's refresh token.
 *
 * `verifier` is the PKCE code verifier whose challenge went to GitHub with the sign-in.
 * GitHub issues nothing without it, so a code alone, which passes through the relay's
 * address, is worth nothing to someone who saw it.
 *
 * Returns undefined when GitHub refuses the code or the verifier, or when the App's user
 * tokens don't expire, because then GitHub issues no refresh token. Throws when GitHub
 * can't be reached.
 */
export async function refreshTokenForCode(
  app: AppCredentials,
  code: string,
  verifier: string,
  redirectURL: string,
): Promise<string | undefined> {
  try {
    // Octokit's `exchangeWebFlowCode` has no parameter for the verifier.
    const response = await request("POST https://github.com/login/oauth/access_token", {
      headers: { accept: "application/json" },
      client_id: app.clientID,
      client_secret: app.clientSecret,
      code,
      redirect_uri: redirectURL,
      code_verifier: verifier,
    });
    const answer = TokenAnswer.safeParse(response.data);
    if (!answer.success || answer.data.error !== undefined) {
      return undefined;
    }

    const { refresh_token: refreshToken } = answer.data;

    return typeof refreshToken === "string" ? refreshToken : undefined;
  } catch (error) {
    if (refusedByGitHub(error)) {
      return undefined;
    }

    throw error;
  }
}

/**
 * Octokit puts a status on every error: GitHub's own, 400 for an OAuth error such as a spent
 * token, and 500 when the request failed. Only a 4xx means GitHub refused.
 */
function refusedByGitHub(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return false;
  }

  return typeof error.status === "number" && error.status >= 400 && error.status < 500;
}
