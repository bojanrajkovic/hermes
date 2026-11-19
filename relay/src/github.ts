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
export type Access = {
  refreshToken: string;
  repositories: Repository[];
  /**
   * False only when the user can see no repository and GitHub says they have nothing to do
   * with the organization the client named. A member whose access is still being granted
   * sees no repository either, and stays affiliated.
   */
  affiliated: boolean;
};

// shortcut: reads at most 4,000 repositories, because a Worker on the free plan may make 50
// requests per invocation. Raise it when the relay runs on a paid plan.
const maxPages = 40;
const pageSize = 100;

/**
 * Uses a refresh token, which GitHub replaces, and lists the repositories its user can see
 * through the tenant's App.
 *
 * When the list is empty and the client named an organization, it also asks GitHub whether
 * the user belongs to it. The token is the tenant App's, so GitHub answers for an
 * organization only where that App is installed.
 *
 * Returns undefined when GitHub refuses the token. Throws when GitHub can't be reached or
 * the listing fails. The old token is spent by then, so the user has to sign in again.
 */
export async function accessForRefreshToken(
  app: AppCredentials,
  token: string,
  organization: string | undefined,
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

  const affiliated =
    repositories.length > 0 ||
    organization === undefined ||
    (await belongsTo(organization, headers));

  return { refreshToken: authentication.refreshToken, repositories, affiliated };
}

/**
 * Whether the token's user is a member of an organization, or has an invitation to it.
 *
 * Only GitHub's 404, "not affiliated", counts as no. A refusal for another reason, or no
 * answer at all, leaves the question open, and the socket stays open with its empty list,
 * as it would with no organization named.
 */
async function belongsTo(
  organization: string,
  headers: { authorization: string },
): Promise<boolean> {
  return await request("GET /user/memberships/orgs/{org}", { headers, org: organization }).then(
    () => true,
    (error: unknown) => status(error) !== 404,
  );
}

/**
 * Octokit puts a status on every error: GitHub's own, 400 for an OAuth error such as a spent
 * token, and 500 when the request failed. Only a 4xx means GitHub refused.
 */
function refusedByGitHub(error: unknown): boolean {
  const code = status(error);

  return code !== undefined && code >= 400 && code < 500;
}

/** The HTTP status Octokit put on an error. */
function status(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return undefined;
  }

  return typeof error.status === "number" ? error.status : undefined;
}
