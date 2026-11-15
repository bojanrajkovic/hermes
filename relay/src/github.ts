import { exchangeWebFlowCode } from "@octokit/oauth-methods";
import type { Registration } from "./registration";

type AppCredentials = Pick<Registration, "clientID" | "clientSecret">;

/**
 * Trades the code GitHub gave the browser at sign-in for the user's refresh token.
 *
 * Returns undefined when GitHub refuses the code, or when the App's user tokens
 * don't expire, because then GitHub issues no refresh token. Throws when GitHub
 * can't be reached.
 */
export async function refreshTokenForCode(
  app: AppCredentials,
  code: string,
  redirectURL: string,
): Promise<string | undefined> {
  try {
    const { authentication } = await exchangeWebFlowCode({
      clientType: "github-app",
      clientId: app.clientID,
      clientSecret: app.clientSecret,
      code,
      redirectUrl: redirectURL,
    });
    return "refreshToken" in authentication ? authentication.refreshToken : undefined;
  } catch (error) {
    if (refusedByGitHub(error)) return undefined;
    throw error;
  }
}

/** Octokit gives an error a status when GitHub answered, and none when the request failed. */
function refusedByGitHub(error: unknown): boolean {
  return typeof error === "object" && error !== null && "status" in error;
}
