import UIKit

class ViewController: UITableViewController {
    var repos = NSArray()

    override func viewDidLoad() {
        super.viewDidLoad()

        downloadRepositories(username: "ashfurrow")
    }

    // MARK: - API Stuff

    func downloadRepositories(username: String) {
        _ = GitHubProvider.request(.userRepositories(username), completion: { result in

            var success = true
            var message = "Unable to fetch from GitHub"
            
            switch result {
            case let .Success(response):
                do {
                    let json: NSArray? = try response.mapJSON() as? NSArray
                    if let json = json {
                        // Presumably, you'd parse the JSON into a model object. This is just a demo, so we'll keep it as-is.
                        self.repos = json
                    } else {
                        success = false
                    }
                } catch {
                    success = false
                }
                self.tableView.reloadData()
            case let .Failure(error):
                guard let error = error as? CustomStringConvertible else {
                    break
                }
                message = error.description
                success = false
            }
            
            if !success {
                let alertController = UIAlertController(title: "GitHub Fetch", message: message, preferredStyle: .alert)
                let ok = UIAlertAction(title: "OK", style: .default, handler: { (action) -> Void in
                    alertController.dismiss(animated: true, completion: nil)
                })
                alertController.addAction(ok)
                self.present(alertController, animated: true, completion: nil)
            }
        })
    }

    func downloadZen() {
        _ = GitHubProvider.request(.zen, completion: { result in
            var message = "Couldn't access API"
            if case let .Success(response) = result {
                message = (try? response.mapString()) ?? message
            }

            let alertController = UIAlertController(title: "Zen", message: message, preferredStyle: .alert)
            let ok = UIAlertAction(title: "OK", style: .default, handler: { (action) -> Void in
                alertController.dismiss(animated: true, completion: nil)
            })
            alertController.addAction(ok)
            self.present(alertController, animated: true, completion: nil)
        })
    }

    // MARK: - User Interaction


    @IBAction func searchWasPressed(_ sender: UIBarButtonItem) {
        var usernameTextField: UITextField?
        
        let promptController = UIAlertController(title: "Username", message: nil, preferredStyle: .alert)
        let ok = UIAlertAction(title: "OK", style: .default, handler: { (action) -> Void in
            if let usernameTextField = usernameTextField {
                self.downloadRepositories(username: usernameTextField.text!)
            }
        })
        _ = UIAlertAction(title: "Cancel", style: .cancel) { (action) -> Void in
        }
        promptController.addAction(ok)
        promptController.addTextField(configurationHandler: { (textField) -> Void in
            usernameTextField = textField
        })
        present(promptController, animated: true, completion: nil)
    }


    @IBAction func zenWasPressed(_ sender: UIBarButtonItem) {
        downloadZen()
    }
    // MARK: - Table View

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return repos.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as UITableViewCell
        
        let object = repos[indexPath.row] as! NSDictionary
        (cell.textLabel as UILabel!).text = object["name"] as? String
        return cell
    }
}

