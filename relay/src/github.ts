import { refreshToken as refresh } from "@octokit/oauth-methods";
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
  const refreshed = await refresh({
    clientType: "github-app",
    clientId: app.clientID,
    clientSecret: app.clientSecret,
    refreshToken: token,
  }).catch((error: unknown) => {
    if (refusedByGitHub(error)) {
      return undefined;
    }

    throw error;
  });
  if (refreshed === undefined) {
    return undefined;
  }

  const { authentication } = refreshed;
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
      if (data.repositories.length < pageSize) {
        break;
      }
    }
  }

  return { refreshToken: authentication.refreshToken, repositories };
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
