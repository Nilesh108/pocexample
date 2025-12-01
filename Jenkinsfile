pipeline {
  agent any

  environment {
    // Azure service principal – configure as needed
    SPOC_CLIENT_ID       = ''
    SPOC_CLIENT_SECRET   = ''
    SPOC_SUBSCRIPTION_ID = ''
    SPOC_TENANT_ID       = ''
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Terraform Init & Plan') {
      steps {
        sh 'terraform init'
        sh 'terraform plan -out=tfplan'
      }
    }

    stage('Terraform Apply') {
      steps {
        sh 'terraform apply -auto-approve tfplan'
      }
    }

    stage('Smoke Test') {
      steps {
        script {
          // Read LB public IP from Terraform output
          def ip = sh(
            script: "terraform output -raw lb_public_ip",
            returnStdout: true
          ).trim()

          sh "echo 'Hitting http://${ip} ...'"
          sh "curl -I http://${ip}"
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'terraform.tfstate', onlyIfSuccessful: true
    }
  }
}

