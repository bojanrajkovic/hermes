import { exchangeWebFlowCode, refreshToken as refresh } from "@octokit/oauth-methods";
import { request } from "@octokit/request";
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

/** Octokit gives an error a status when GitHub answered, and none when the request failed. */
function refusedByGitHub(error: unknown): boolean {
  return typeof error === "object" && error !== null && "status" in error;
}
