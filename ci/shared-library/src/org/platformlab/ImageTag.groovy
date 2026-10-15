package org.platformlab

/**
 * One rule for image tags, shared by every team.
 *
 * Why a class in src/ rather than a step in vars/: this is plain logic with no
 * pipeline steps in it, so it can be unit-tested and reused from any step.
 * vars/ is for the things a Jenkinsfile calls; src/ is for the code behind them.
 *
 * The tag is <branch>-<shortsha>-<build>, never `latest`:
 *   - the SHA says exactly which code is in the image
 *   - the build number disambiguates a rebuild of the same commit
 *   - the branch prefix keeps feature-branch images visibly separate from main
 * `latest` cannot be rolled back to, because it has already moved.
 */
class ImageTag implements Serializable {
    static String of(String branch, String sha, String buildNumber) {
        String b = (branch ?: 'detached').toLowerCase().replaceAll(/[^a-z0-9.-]/, '-')
        if (b.length() > 40) { b = b.substring(0, 40) }
        String s = (sha ?: 'nosha').take(8)
        return "${b}-${s}-${buildNumber}"
    }
}
