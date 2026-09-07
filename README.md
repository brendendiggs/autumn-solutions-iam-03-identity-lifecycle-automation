# Project 03 — Identity Lifecycle Automation

## Overview

Built an end-to-end Joiner–Mover–Leaver identity lifecycle automation workflow for a fictional organization, Autumn Solutions, using a live Google Sheets HR source, Microsoft Entra ID, and Microsoft Graph.

The project simulates an HR-driven identity lifecycle process where a structured HR source feed triggers identity creation, attribute updates, access changes, and account disablement.

## Architecture

Live Google Sheets HR Source  
→ Batch lifecycle controller  
→ Joiner / Mover / Leaver automation  
→ Microsoft Graph API  
→ Microsoft Entra ID

The HR feed acts as the source of truth for identity lifecycle events and employee attributes.

## Technologies

- Microsoft Entra ID
- Microsoft Graph API
- OAuth 2.0 Client Credentials Flow
- App Registrations / Service Principals
- zsh shell scripting
- Live Google Sheets HR source integration
- Entra security groups

## HR Source Feed

The lifecycle controller processes HR events using this schema:

`username,displayName,department,jobTitle,event`

Supported lifecycle events:

- Joiner
- Mover
- Leaver

## HR Source Integration

The lifecycle controller retrieves the current HR event feed directly from Google Sheets before processing identity changes.

Workflow:

Google Sheets HR source → HTTPS CSV retrieval → schema validation → lifecycle controller → Microsoft Graph → Microsoft Entra ID

The automation:

- Retrieves the latest HR data at runtime
- Validates the expected CSV schema before processing
- Replaces the local working feed only after successful validation
- Eliminates the manual CSV export step
- Treats the HR source as authoritative for lifecycle attributes

For this fictional lab, the sheet is read-only and link-accessible. A production implementation would use an authenticated HRIS or Google Sheets API integration rather than publicly accessible HR data.

## Joiner Workflow

The Joiner workflow:

1. Reads the new employee from the HR source feed.
2. Checks whether the identity already exists in Entra ID.
3. Creates the Entra user through Microsoft Graph if the identity does not exist.
4. Sets the employee's display name, department, job title, and usage location.
5. Maps the employee's department to the appropriate security group.
6. Adds the employee to the department security group.
7. Adds the employee to SG-All-Employees.
8. Assigns a Microsoft Entra ID P2 license through Microsoft Graph.
9. Verifies required state before licensing and retries transient licensing propagation failures.
10. Uses existence and membership checks so repeated execution remains safe and idempotent.

Example:

Lena Ortiz

- Department: Information Technology
- Job title: Security Analyst
- Assigned to SG-IT
- Assigned to SG-All-Employees
- Usage location configured
- Microsoft Entra ID P2 license assigned

## Mover Workflow

The Mover workflow treats the HR source feed as the authoritative source for employee attributes.

The workflow:

1. Reads the employee's new department and job title from the HR feed.
2. Updates the Entra identity through Microsoft Graph.
3. Validates the Graph API response.
4. Reads the identity back from Entra to verify the expected state.
5. Determines the correct access group from the updated department.
6. Adds the employee to the new department group.
7. Removes obsolete department access.
8. Preserves baseline SG-All-Employees access.
9. Uses idempotent membership checks so repeated execution remains safe.

Example:

Priya Shah
- Previous department: Human Resources
- New department: Finance
- New job title: Finance Specialist
- Removed from SG-HR
- Added to SG-Finance
- Preserved membership in SG-All-Employees

## Leaver Workflow

The Leaver workflow:

1. Identifies the departing employee.
2. Removes department-based group memberships.
3. Removes SG-All-Employees membership.
4. Reclaims the Microsoft Entra ID P2 license.
5. Disables the Entra user account.
6. Preserves the identity object for audit and historical purposes rather than deleting it.
7. Uses state checks so repeated execution remains safe.

Example:

Avery Collins

- Removed from SG-IT
- Removed from SG-All-Employees
- Microsoft Entra ID P2 license reclaimed
- Entra account disabled

## Department-to-Access Mapping

- Finance → SG-Finance
- Human Resources → SG-HR
- Sales → SG-Sales
- Operations → SG-Operations
- Information Technology → SG-IT

All active workforce users also receive:

- SG-All-Employees

## Microsoft Graph Application Permissions

The automation application uses Microsoft Graph application permissions including:

- User.Read.All
- User.ReadWrite.All
- Group.Read.All
- GroupMember.ReadWrite.All
- LicenseAssignment.Read.All
- LicenseAssignment.ReadWrite.All

Admin consent was granted for the required application permissions.

## Authentication Model

The automation uses the OAuth 2.0 Client Credentials Flow with X.509 certificate-based workload authentication.

The workload authenticates using:

- Tenant ID
- Client ID
- X.509 certificate registered with the Autumn Graph Automation app
- Private key stored securely outside the project directory

The automation creates a short-lived signed client assertion using the private key and exchanges it with Microsoft Entra ID for a Microsoft Graph access token.

The lifecycle automation does not require or use a client secret.

## Security and Reliability Controls

The project includes:

- Runtime credential injection instead of hard-coded secrets
- API HTTP status validation
- Post-update state verification
- Idempotent user and group membership checks
- Automated license assignment and reclamation
- Usage-location validation before license assignment
- Retry handling for transient licensing propagation delays
- Live HR-source synchronization and schema validation
- Separation between source-of-truth attributes and access logic
- Account disablement instead of automatic deletion for leavers
- Controlled department-to-group mapping
- Error handling for failed Graph operations
- Persistent structured lifecycle audit logging

The lifecycle controller writes timestamped Joiner, Mover, and Leaver results to:

`logs/lifecycle-audit.csv`

Each record includes:

- Timestamp
- Event type
- Username
- Result
- Message

## Production Hardening

The lab was upgraded from shared-secret authentication to X.509 certificate-based workload authentication.

The public certificate is registered with the Autumn Graph Automation app registration, while the private key remains outside the project directory and is never committed with project files.

A production deployment could further strengthen the design with:

- Managed identity where supported
- Workload identity federation
- Centralized certificate and key lifecycle management
- Automated certificate rotation
- Authenticated HRIS or Google Sheets API integration
- Centralized monitoring and alerting

## Key IAM Concepts Demonstrated

- Joiner–Mover–Leaver lifecycle management
- Identity provisioning
- Attribute-driven access control
- Entitlement assignment
- Automated license assignment
- License reclamation
- Access removal
- Least privilege
- Workload identities
- OAuth 2.0 client credentials
- Certificate-based workload authentication
- Signed client assertions
- Microsoft Graph automation
- Authoritative HR-source integration
- Source-of-truth design
- State verification
- Idempotent automation
- Structured lifecycle audit logging
- Account deprovisioning

## Project Files

- `process_hr_events.sh` — Batch lifecycle controller and audit logging
- `get_graph_token.mjs` — Certificate-based Microsoft Graph token acquisition
- `joiner.sh` — User creation, access provisioning, and license assignment
- `mover.sh` — Attribute-driven access transition
- `leaver.sh` — Access removal, license reclamation, and account disablement
- `hr_events.csv` — Runtime working copy of the synchronized HR lifecycle feed
- `logs/lifecycle-audit.csv` — Structured lifecycle audit trail
- `screenshots/` — Project evidence and validation screenshots

## Evidence

Evidence captured for the project includes:

- HR source-of-truth feed
- Live Google Sheets HR-source integration verified through an Entra attribute update
- Automated Joiner creation and access assignment
- Lena Ortiz final identity state
- Lena Ortiz final group memberships
- Priya Shah final identity state
- Priya Shah final access state
- Marcus Bell account disablement
- Marcus Bell access removal
- Successful terminal output for Joiner processing
- Successful terminal output for Mover and Leaver processing
- Automated Microsoft Entra ID P2 license assignment verified through Graph
- Structured Joiner, Mover, and Leaver audit logging
- Leaver license reclamation and account disablement verified through Graph
- Certificate-based Microsoft Graph authentication verified without a client secret
- Full six-event JML pipeline completed successfully using certificate-only authentication

## Outcome

Successfully built and validated a reusable identity lifecycle automation pipeline that processes Joiner, Mover, and Leaver events against Microsoft Entra ID using Microsoft Graph.

The final workflow demonstrates how identity attributes retrieved directly from an authoritative HR source can drive automated account creation, attribute changes, department-based access, license assignment, state verification, license reclamation, account disablement, and persistent lifecycle audit logging.

A live-source test changed Priya Shah's job title in Google Sheets to Senior Finance Specialist. The lifecycle controller retrieved the updated feed automatically and Microsoft Graph updated the corresponding Entra identity without a manual CSV export.

The automation also demonstrates idempotent execution, retry handling for real-world cloud propagation behavior, and certificate-secured workload authentication without a shared client secret.