pipeline{
    agent any
    tools{
        jdk 'jdk'
        nodejs 'node'
    }
    environment {
        SCANNER_HOME=tool 'sonar-scanner'
    }
    stages {
        stage('clean workspace'){
            steps{
                cleanWs()
            }
        }
        stage('Checkout from Git'){
            steps{
                git branch: 'main', url: 'https://github.com/wiamelyakini/the-briefing.git'
            }
        }
        stage("Sonarqube Analysis "){
            steps{
                withSonarQubeEnv('SonarQube') {
                    sh ''' $SCANNER_HOME/bin/sonar-scanner -Dsonar.projectName=TheBriefing \
                    -Dsonar.projectKey=TheBriefing '''
                }
            }
        }
        stage("quality gate"){
           steps {
                script {
                    waitForQualityGate abortPipeline: false, credentialsId: 'Sonar-token' 
                }
            } 
        }
        stage('Install Dependencies') {
            steps {
                sh "npm install"
            }
        }
        stage('OWASP FS SCAN') {
            steps {
                dependencyCheck additionalArguments: '--scan ./ --disableYarnAudit --disableNodeAudit --nvdApiKey d7e8c629-7da9-4f96-8a4a-a45fd3f213ba', odcInstallation: 'DC'
                dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
           }
        }
            stage('TRIVY FS SCAN') {
            steps {
                sh "trivy fs . > trivyfs.txt"
            }
        }
        stage("Docker Build & Push"){
            steps{
                script{
                   withDockerRegistry(credentialsId: 'docker', toolName: 'docker'){   
                       sh "docker build -t the-briefing ."
                       sh "docker tag the-briefing wiameelyakini/the-briefing:latest "
                       sh "docker push wiameelyakini/the-briefing:latest "
                    }
                }
            }
        }
        stage("TRIVY"){
            steps{
                sh "trivy image wiameelyakini/the-briefing:latest > trivyimage.txt" 
            }
        }
        stage('Deploy to Staging') {
            steps {
                sh 'kubectl apply -f K8S/staging.yml'
                sh 'kubectl rollout status deployment/the-briefing-deployment -n staging'
            }
        }
        stage('Approve Production Deploy') {
            steps {
                input message: 'Staging looks good — promote to production?', ok: 'Deploy to Production'
            }
        }
        stage('Deploy to Production') {
            steps {
                sh 'kubectl apply -f K8S/manifest.yml'
                sh 'kubectl rollout status deployment/the-briefing-deployment -n production'
            }
        }

    }
    post {
    always {
        script {
            def buildStatus = currentBuild.currentResult
            def buildUser = currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')[0]?.userId ?: 'Github User'
            
            emailext (
                subject: "Pipeline ${buildStatus}: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: """
                    <p>This is a Jenkins The Briefing CICD pipeline status.</p>
                    <p>Project: ${env.JOB_NAME}</p>
                    <p>Build Number: ${env.BUILD_NUMBER}</p>
                    <p>Build Status: ${buildStatus}</p>
                    <p>Started by: ${buildUser}</p>
                    <p>Build URL: <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></p>
                """,
                to: 'wiame.el-yakini@estiam.com',
                from: 'wiame.el-yakini@estiam.com',
                replyTo: 'wiame.el-yakini@estiam.com',
                mimeType: 'text/html',
                attachmentsPattern: 'trivyfs.txt,trivyimage.txt'
            )
           }
       }

    }

}
