import { refreshToken as refresh } from "@octokit/oauth-methods";
import { request } from "@octokit/request";
import type { Registration } from "./registration";

type AppCredentials = Pick<Registration, "clientID" | "clientSecret">;

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
    // GitHub answers 200 with an `error` field when it refuses.
    const answer = response.data as { refresh_token?: unknown; error?: unknown };
    if (answer.error !== undefined) return undefined;
    return typeof answer.refresh_token === "string" ? answer.refresh_token : undefined;
  } catch (error) {
    if (refusedByGitHub(error)) return undefined;
    throw error;
  }
}

export type Repository = { id: number; fullName: string };

/** What a refresh token is worth: its replacement, and the repositories its user can see. */
export type Access = { refreshToken: string; repositories: Repository[] };

// shortcut: reads at most 4,000 repositories, because a Worker on the free plan may make 50
// requests per invocation. Raise it when the relay runs on a paid plan.
const maxPages = 40;
const pageSize = 100;

/**
 * Uses a refresh token, which GitHub replaces, and lists the repositories its user can see
 * through the tenant's App.
 *
 * Returns undefined when GitHub refuses the token. Throws when GitHub can't be reached or
 * the listing fails. The old token is spent by then, so the user has to sign in again.
 */
export async function accessForRefreshToken(
  app: AppCredentials,
  token: string,
): Promise<Access | undefined> {
  let authentication;
  try {
    ({ authentication } = await refresh({
      clientType: "github-app",
      clientId: app.clientID,
      clientSecret: app.clientSecret,
      refreshToken: token,
    }));
  } catch (error) {
    if (refusedByGitHub(error)) return undefined;
    throw error;
  }

  const headers = { authorization: `token ${authentication.token}` };
  const installations = await request("GET /user/installations", { headers, per_page: pageSize });

  const repositories: Repository[] = [];
  let pages = 0;
  for (const installation of installations.data.installations) {
    for (let page = 1; pages < maxPages; page += 1) {
      pages += 1;
      const { data } = await request("GET /user/installations/{installation_id}/repositories", {
        headers,
        installation_id: installation.id,
        per_page: pageSize,
        page,
      });
      repositories.push(
        ...data.repositories.map((r) => ({ id: Number(r.id), fullName: r.full_name })),
      );
      if (data.repositories.length < pageSize) break;
    }
  }
  return { refreshToken: authentication.refreshToken, repositories };
}

/**
 * Octokit puts a status on every error: GitHub's own, 400 for an OAuth error such as a spent
 * token, and 500 when the request failed. Only a 4xx means GitHub refused.
 */
function refusedByGitHub(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("status" in error)) return false;
  return typeof error.status === "number" && error.status >= 400 && error.status < 500;
}
