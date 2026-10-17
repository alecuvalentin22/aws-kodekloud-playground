// (h) JOB DSL: jobs as code. The seed job (jt-seed) runs this file; the jobs it
// defines appear (or are updated, or deleted) in Jenkins. This is how the
// playground's own demo-api job exists: see setup/jenkins-values-local.yaml.
pipelineJob('jt-dsl-pipeline') {
    description('Created by jobs/dsl.groovy. Do not edit in the UI: the next seed run puts it back.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('http://gitea.git.svc.cluster.local:3000/payments/jobtypes-demo.git') }
                    branch('main')
                }
            }
            scriptPath('Jenkinsfile')
            lightweight(true)
        }
    }
}

job('jt-dsl-freestyle') {
    description('Created by jobs/dsl.groovy.')
    label('jenkins-jenkins-agent')
    steps { shell('echo "a freestyle job, defined in code"') }
}
